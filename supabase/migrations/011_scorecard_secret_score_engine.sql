-- =====================================================================
-- 011_scorecard_secret_score_engine.sql   (PHASE A of the win engine)
--
-- Adds the wins ledger, the idempotency marker, and the atomic evaluation
-- RPC that decides a round's secret-score outcome. Migration 010 created the
-- config/combos/prizes/current tables + the anon-locked security boundary;
-- this builds the engine on top of it.
--
-- LOCKED DESIGN DECISIONS baked in here:
--   1. Idempotency marker = scorecard.games.secret_evaluated (a column, not a
--      side table). Atomically flipped false->true to elect the sole evaluator.
--   2. The engine is a SECURITY DEFINER RPC (owned by the migration/superuser
--      role) so it bypasses RLS on the secret tables. It is anon-EXECUTABLE but
--      NEVER returns the secret hole/score — only won/prize/reveal/code. No
--      service-role key is handled anywhere; the secret never leaves Postgres.
--   3. redeem_code = 8 chars, ambiguity-free alphabet (no 0/O/1/I), UNIQUE,
--      collision-retried against the unique index.
--   4. is_test rounds NEVER evaluate (so they can't win, rotate, or count to the
--      cap). Enforced in the first-evaluator claim; test rounds also never reach
--      secret_score_wins, so the cap count (which reads that table) excludes them
--      for free.
--   5. Only status='completed' rounds evaluate; abandoned never wins.
--
-- RACE/IDEMPOTENCY MODEL:
--   - First-evaluator election: UPDATE ... WHERE secret_evaluated=false (row lock)
--     RETURNING. Exactly one concurrent caller wins; the rest read the stored
--     result and return it unchanged (no re-draw, re-award, or re-rotate).
--   - Per-location advisory xact lock serializes cap-counting + rotation so two
--     different rounds finishing at once can't double-draw or race the cap.
--   - UNIQUE(game_id) on the wins table is the final belt-and-suspenders guard:
--     at most one prize per round, enforced by Postgres.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Idempotency marker on the round itself
-- ---------------------------------------------------------------------
-- Written only by the engine RPC (definer). Anon can insert games but RLS
-- forbids updating this column, so guests can never pre-mark a round.
alter table scorecard.games
  add column if not exists secret_evaluated boolean not null default false;
comment on column scorecard.games.secret_evaluated is
  'true once the secret-score engine has evaluated this round; engine-managed, idempotency guard.';

-- ---------------------------------------------------------------------
-- 2. The wins ledger
-- ---------------------------------------------------------------------
-- One row per WINNING round (shared by all matching players in that round).
-- UNIQUE(game_id) => a round can win at most once. UNIQUE(redeem_code) => the
-- code staff type at the desk maps to exactly one win.
create table if not exists scorecard.secret_score_wins (
  id                  uuid primary key default gen_random_uuid(),
  location_id         uuid not null references public.locations(id) on delete restrict,
  game_id             uuid not null references scorecard.games(id) on delete cascade,
  hole                int  not null check (hole >= 1),
  score               int  not null check (score >= 1),
  prize_id            uuid references scorecard.secret_score_prizes(id) on delete set null,
  prize_name_snapshot text not null,                 -- frozen at draw time (prizes can change)
  redeem_code         text not null,
  redeemed            boolean not null default false,
  redeemed_by         uuid references public.profiles(id) on delete set null,
  redeemed_at         timestamptz,
  created_at          timestamptz not null default now(),
  unique (game_id),
  unique (redeem_code)
);
create index if not exists secret_score_wins_loc_created_idx
  on scorecard.secret_score_wins(location_id, created_at);   -- cap counting + desk listing
create index if not exists secret_score_wins_loc_redeemed_idx
  on scorecard.secret_score_wins(location_id, redeemed);

-- ---------------------------------------------------------------------
-- 3. RLS + grants on the wins ledger
-- ---------------------------------------------------------------------
-- anon: NONE (RLS enabled, no anon policy; grants revoked). The engine writes
-- here as the definer role, which bypasses RLS. Staff with redeem capability
-- may read wins and flip the redemption columns for their location(s).
alter table scorecard.secret_score_wins enable row level security;

grant usage on schema scorecard to authenticated;
grant select, update on scorecard.secret_score_wins to authenticated;
revoke all on scorecard.secret_score_wins from anon, public;

-- READ: redeem capability + can-access this location (mirrors secret_score_current
-- read policy so the broader desk roles can see wins to redeem).
create policy staff_read_secret_wins on scorecard.secret_score_wins
  for select to authenticated
  using (scorecard.has_capability('redeem_secret_score')
         and gz360_auth.gz_can_access_location(location_id));

-- UPDATE (redemption): same predicate on both sides. The app only changes the
-- redeemed/redeemed_by/redeemed_at columns; tightening to specific columns is
-- left to the redemption-flow session.
create policy staff_redeem_secret_wins on scorecard.secret_score_wins
  for update to authenticated
  using (scorecard.has_capability('redeem_secret_score')
         and gz360_auth.gz_can_access_location(location_id))
  with check (scorecard.has_capability('redeem_secret_score')
              and gz360_auth.gz_can_access_location(location_id));

-- ---------------------------------------------------------------------
-- 4. redeem_code generator (ambiguity-free 8-char codes)
-- ---------------------------------------------------------------------
-- 32-char alphabet: A-Z minus I/O, digits 2-9 minus 0/1. Uniqueness is enforced
-- by the unique index; the RPC retries on collision.
create or replace function scorecard.gen_redeem_code()
returns text
language sql
volatile
as $$
  select string_agg(
           substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
                  1 + floor(random() * 32)::int, 1),
           '')
  from generate_series(1, 8);
$$;

-- ---------------------------------------------------------------------
-- 5. The atomic evaluation engine
-- ---------------------------------------------------------------------
-- Returns jsonb: {won:false} OR {won:true, prize_name, reveal_text, redeem_code}.
-- NEVER returns the secret hole/score. Idempotent + race-safe (see header).
create or replace function scorecard.evaluate_secret_score(p_game_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = scorecard, public
as $$
declare
  v_loc         uuid;
  v_scores      jsonb;
  v_enabled     boolean;
  v_cap         int;
  v_reveal      text;
  v_pool_mode   text;
  v_holes       int[];
  v_scores_cfg  int[];
  v_hole        int;
  v_score       int;
  v_match       boolean;
  v_midnight    timestamptz;
  v_today_wins  int;
  v_prize_id    uuid;
  v_prize_name  text;
  v_code        text;
  v_win         scorecard.secret_score_wins%rowtype;
  v_next_hole   int;
  v_next_score  int;
  i             int;
begin
  -- (1) Elect the sole first-evaluator. Only completed, non-test rounds qualify.
  update scorecard.games g
     set secret_evaluated = true
   where g.id = p_game_id
     and g.status = 'completed'
     and g.is_test = false
     and g.secret_evaluated = false
  returning g.location_id, g.scores
       into v_loc, v_scores;

  if not found then
    -- Already evaluated, or ineligible (abandoned / test / unknown id).
    -- Return the stored outcome verbatim — no re-draw / re-award / re-rotate.
    select * into v_win
      from scorecard.secret_score_wins
     where game_id = p_game_id;
    if found then
      return jsonb_build_object(
        'won', true,
        'prize_name', v_win.prize_name_snapshot,
        'reveal_text', (select win_reveal_text
                          from scorecard.secret_score_config
                         where location_id = v_win.location_id),
        'redeem_code', v_win.redeem_code);
    end if;
    return jsonb_build_object('won', false);
  end if;

  -- From here we are the unique evaluator for this round.
  -- Serialize cap-count + rotation for this location against concurrent rounds.
  perform pg_advisory_xact_lock(hashtext(v_loc::text));

  -- (2) Location config + live secret.
  select sc.enabled, sc.daily_win_cap, sc.win_reveal_text,
         sc.pool_mode, sc.allowed_holes, sc.allowed_scores
    into v_enabled, v_cap, v_reveal, v_pool_mode, v_holes, v_scores_cfg
    from scorecard.secret_score_config sc
   where sc.location_id = v_loc;

  if not found or v_enabled is distinct from true then
    return jsonb_build_object('won', false);
  end if;

  select cur.hole, cur.score
    into v_hole, v_score
    from scorecard.secret_score_current cur
   where cur.location_id = v_loc;

  if not found then
    return jsonb_build_object('won', false);   -- feature enabled but no secret drawn yet
  end if;

  -- (3) Did ANY player card exactly v_score on hole v_hole? (1-based -> idx v_hole-1)
  select exists (
    select 1
      from jsonb_array_elements(v_scores) as t(arr)
     where (t.arr ->> (v_hole - 1))::int = v_score
  ) into v_match;

  if not v_match then
    return jsonb_build_object('won', false);
  end if;

  -- (4) Daily cap (America/Toronto). Wins table never holds test rounds, so the
  -- count already excludes them.
  if v_cap is not null then
    v_midnight := date_trunc('day', now() at time zone 'America/Toronto')
                    at time zone 'America/Toronto';
    select count(*) into v_today_wins
      from scorecard.secret_score_wins
     where location_id = v_loc
       and created_at >= v_midnight;
    if v_today_wins >= v_cap then
      return jsonb_build_object('won', false);   -- capped: no win, secret NOT rotated
    end if;
  end if;

  -- (5) Weighted-random prize draw (Efraimidis-Spirakis) from active prizes.
  select p.id, p.name
    into v_prize_id, v_prize_name
    from scorecard.secret_score_prizes p
   where p.location_id = v_loc and p.is_active and p.weight > 0
   order by -ln(random()) / p.weight
   limit 1;

  if v_prize_id is null then
    return jsonb_build_object('won', false);   -- nothing to award; do not rotate
  end if;

  -- (6) Record the win (one per game_id). Retry only on redeem_code collision.
  for i in 1..12 loop
    begin
      v_code := scorecard.gen_redeem_code();
      insert into scorecard.secret_score_wins(
        location_id, game_id, hole, score, prize_id, prize_name_snapshot, redeem_code)
      values (v_loc, p_game_id, v_hole, v_score, v_prize_id, v_prize_name, v_code);
      exit;   -- success
    exception when unique_violation then
      -- game_id is ours under the advisory lock, so this is a redeem_code clash.
      if i = 12 then raise; end if;
    end;
  end loop;

  update scorecard.games set won_prize = true where id = p_game_id;

  -- (7) Rotate the secret per pool_mode (consume the won secret, draw the next).
  if v_pool_mode = 'random' then
    if coalesce(array_length(v_holes, 1), 0) > 0
       and coalesce(array_length(v_scores_cfg, 1), 0) > 0 then
      v_next_hole  := v_holes[1 + floor(random() * array_length(v_holes, 1))::int];
      v_next_score := v_scores_cfg[1 + floor(random() * array_length(v_scores_cfg, 1))::int];
    end if;
  else  -- 'curated'
    select c.hole, c.score
      into v_next_hole, v_next_score
      from scorecard.secret_score_combos c
     where c.location_id = v_loc and c.is_active and c.weight > 0
     order by -ln(random()) / c.weight
     limit 1;
  end if;

  if v_next_hole is not null and v_next_score is not null then
    update scorecard.secret_score_current
       set hole = v_next_hole, score = v_next_score, drawn_at = now()
     where location_id = v_loc;
  else
    -- Empty/undrawable pool: the won secret is left in place (leave-in-place is
    -- intentional — see NOTE below). Should be near-impossible since the admin UI
    -- requires a non-empty pool to enable; logged so a stuck/re-winnable secret is
    -- diagnosable from the Postgres logs rather than failing silently.
    raise log 'secret_score: win recorded for game % at location % but draw pool empty (pool_mode=%) — secret left in place, NOT rotated',
      p_game_id, v_loc, v_pool_mode;
  end if;
  -- NOTE: leave-in-place means a just-won secret with an empty pool could be won
  -- again until the admin reconfigures. Intentional per design; the raise log
  -- above makes the (near-impossible) occurrence visible.

  return jsonb_build_object(
    'won', true,
    'prize_name', v_prize_name,
    'reveal_text', v_reveal,
    'redeem_code', v_code);
end;
$$;

-- anon may invoke the engine (it returns only safe fields); the definer rights
-- read the secret tables internally. Lock down PUBLIC, grant the two app roles.
revoke all on function scorecard.evaluate_secret_score(uuid) from public;
grant execute on function scorecard.evaluate_secret_score(uuid) to anon, authenticated;

commit;

-- =====================================================================
-- NOTES / things to confirm
-- =====================================================================
-- A. SECURITY DEFINER owner: this function bypasses RLS only if its OWNER is a
--    role that bypasses RLS on the secret tables (the table owner / migration
--    superuser, as with scorecard.has_capability + is_location_visible). Apply
--    this migration as that same privileged role so ownership matches.
--
-- B. Residual trust note (inherent, not new): game_id is a client-generated
--    random UUID known only to the device that played. Whoever holds it can
--    trigger evaluation and receive the redeem_code. UUIDs are unguessable and
--    this matches the existing anon model (the client already owns roundId).
--
-- C. Empty-pool rotation edge case — see the inline NOTE at step (7).
--
-- Rollback (manual):
--   drop function if exists scorecard.evaluate_secret_score(uuid);
--   drop function if exists scorecard.gen_redeem_code();
--   drop table    if exists scorecard.secret_score_wins;
--   alter table scorecard.games drop column if exists secret_evaluated;
-- =====================================================================
