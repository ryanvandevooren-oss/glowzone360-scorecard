-- =====================================================================
-- 012_scorecard_secret_score_lazy_seed.sql   (PHASE C.5)
--
-- PROBLEM: scorecard.secret_score_current is only written when the engine
-- ROTATES after a win. A freshly-ENABLED location therefore has no current
-- secret and is silently dormant — no round can win until a secret is seeded
-- by hand (we hit this seeding Brampton manually in testing).
--
-- FIX (lazy-seed): the FIRST time an enabled location is evaluated with no
-- current secret, draw an initial secret from its pool, persist it, and evaluate
-- the current round against it (so the first eligible round still has a fair
-- shot). The draw reuses the SAME weighted logic as post-win rotation — both now
-- call one shared helper, scorecard.draw_secret_score(), so there is a single
-- source of truth for "pick a secret from this location's pool".
--
-- WHAT IS PRESERVED (unchanged): the secret_evaluated first-evaluator claim,
-- is_test exclusion, completed-only, daily cap, the per-location advisory lock,
-- unique(game_id), and secret-never-returned. The lazy-seed runs INSIDE the same
-- advisory-locked critical section (after the enabled check, when reading the
-- current secret), so concurrent first-finishes cannot double-seed or race.
--
-- Empty pool (enabled but no active combos / no allowed holes+scores): nothing
-- to draw — seed nothing, win nothing, no error. The location stays dormant
-- until configured, exactly as before.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Shared draw helper (single source of truth for picking a secret)
-- ---------------------------------------------------------------------
-- Returns (o_hole, o_score) drawn from the location's pool per pool_mode:
--   'curated' -> Efraimidis-Spirakis weighted draw from active secret_score_combos
--   'random'  -> uniform pick from allowed_holes x allowed_scores
-- Returns (NULL, NULL) when the pool is empty/undrawable. Config values are
-- passed in (the caller has already read them) to avoid a redundant read.
--
-- SECURITY DEFINER so it can read secret_score_combos regardless of caller, and
-- locked down (revoked from PUBLIC, never granted to anon) so it is ONLY callable
-- from inside the engine — it must never be reachable directly, as it would
-- reveal pool contents.
create or replace function scorecard.draw_secret_score(
  p_location_id uuid,
  p_pool_mode   text,
  p_holes       int[],
  p_scores      int[],
  out o_hole    int,
  out o_score   int)
language plpgsql
volatile
security definer
set search_path = scorecard, public
as $$
begin
  if p_pool_mode = 'random' then
    if coalesce(array_length(p_holes, 1), 0) > 0
       and coalesce(array_length(p_scores, 1), 0) > 0 then
      o_hole  := p_holes[1 + floor(random() * array_length(p_holes, 1))::int];
      o_score := p_scores[1 + floor(random() * array_length(p_scores, 1))::int];
    end if;
  else  -- 'curated'
    select c.hole, c.score
      into o_hole, o_score
      from scorecard.secret_score_combos c
     where c.location_id = p_location_id and c.is_active and c.weight > 0
     order by -ln(random()) / c.weight
     limit 1;
  end if;
  -- o_hole/o_score remain NULL if nothing was drawable (empty pool).
end;
$$;

revoke all on function scorecard.draw_secret_score(uuid, text, int[], int[]) from public;
-- (no grant to anon/authenticated: internal-only; the engine calls it as owner)

-- ---------------------------------------------------------------------
-- Engine: evaluate_secret_score, now with lazy-seed + shared-draw rotation
-- ---------------------------------------------------------------------
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
  -- Serialize seed + cap-count + rotation for this location against concurrent rounds.
  perform pg_advisory_xact_lock(hashtext(v_loc::text));

  -- (2) Location config + enabled gate. A DISABLED location never seeds or wins.
  select sc.enabled, sc.daily_win_cap, sc.win_reveal_text,
         sc.pool_mode, sc.allowed_holes, sc.allowed_scores
    into v_enabled, v_cap, v_reveal, v_pool_mode, v_holes, v_scores_cfg
    from scorecard.secret_score_config sc
   where sc.location_id = v_loc;

  if not found or v_enabled is distinct from true then
    return jsonb_build_object('won', false);
  end if;

  -- (3) Current live secret — LAZY-SEED if none exists yet.
  select cur.hole, cur.score
    into v_hole, v_score
    from scorecard.secret_score_current cur
   where cur.location_id = v_loc;

  if not found then
    -- ── LAZY-SEED ──────────────────────────────────────────────────────
    -- Enabled location with no secret yet (never rotated). Draw the first one
    -- now via the shared helper (same logic as rotation), persist it, and
    -- evaluate THIS round against it so the first eligible round can win.
    -- We are inside the advisory lock, so two concurrent first-finishes can't
    -- both seed: the loser acquires the lock after the winner has inserted the
    -- row and simply reads it on its own pass.
    select d.o_hole, d.o_score
      into v_hole, v_score
      from scorecard.draw_secret_score(v_loc, v_pool_mode, v_holes, v_scores_cfg) d;

    if v_hole is null or v_score is null then
      -- Enabled but empty/undrawable pool (unconfigured). Seed nothing, win
      -- nothing, no error — location stays dormant until combos are added.
      return jsonb_build_object('won', false);
    end if;

    insert into scorecard.secret_score_current(location_id, hole, score, drawn_at)
    values (v_loc, v_hole, v_score, now());
    -- ───────────────────────────────────────────────────────────────────
  end if;

  -- (4) Did ANY player card exactly v_score on hole v_hole? (1-based -> idx v_hole-1)
  select exists (
    select 1
      from jsonb_array_elements(v_scores) as t(arr)
     where (t.arr ->> (v_hole - 1))::int = v_score
  ) into v_match;

  if not v_match then
    return jsonb_build_object('won', false);
  end if;

  -- (5) Daily cap (America/Toronto). Wins table never holds test rounds, so the
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

  -- (6) Weighted-random prize draw (Efraimidis-Spirakis) from active prizes.
  select p.id, p.name
    into v_prize_id, v_prize_name
    from scorecard.secret_score_prizes p
   where p.location_id = v_loc and p.is_active and p.weight > 0
   order by -ln(random()) / p.weight
   limit 1;

  if v_prize_id is null then
    return jsonb_build_object('won', false);   -- nothing to award; do not rotate
  end if;

  -- (7) Record the win (one per game_id). Retry only on redeem_code collision.
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

  -- (8) Rotate the secret (consume the won one, draw the next) via the SAME helper.
  select d.o_hole, d.o_score
    into v_next_hole, v_next_score
    from scorecard.draw_secret_score(v_loc, v_pool_mode, v_holes, v_scores_cfg) d;

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

-- CREATE OR REPLACE preserves the existing grants from 011, but re-affirm them so
-- this migration is self-contained.
revoke all on function scorecard.evaluate_secret_score(uuid) from public;
grant execute on function scorecard.evaluate_secret_score(uuid) to anon, authenticated;

commit;

-- =====================================================================
-- NOTES
-- =====================================================================
-- A. Apply as the same privileged/owner role used for 010/011 so the new helper
--    and the replaced engine are owned by an RLS-bypassing role.
--
-- B. Lazy-seed only fires for an ENABLED location with no current secret. Once a
--    secret exists (seeded here or rotated after a win), this branch is skipped.
--
-- C. Behaviour change summary vs 011: a freshly-enabled, configured location now
--    seeds its first secret on the first eligible finish instead of staying
--    dormant. Nothing else changes; an empty pool still no-ops safely.
--
-- Rollback (manual): re-apply the 011 body of evaluate_secret_score (without the
--   lazy-seed block / shared helper) and:
--   drop function if exists scorecard.draw_secret_score(uuid, text, int[], int[]);
-- =====================================================================
