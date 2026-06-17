-- =====================================================================
-- 015_scorecard_secret_score_prize_image_disclaimer.sql
--
-- Returns the won prize's CURRENT image_url AND disclaimer as `prize_image`
-- and `prize_disclaimer` in the engine's win response, so the guest reveal can
-- show a prize photo + terms. Pairs with 013 (image_url) and 014 (disclaimer).
--
-- WHAT CHANGES (only this):
--   * v_prize_image / v_prize_disclaimer declared; the prize draw also selects
--     p.image_url and p.disclaimer.
--   * The fresh-win return adds 'prize_image' and 'prize_disclaimer'.
--   * The already-evaluated re-return looks up the CURRENT image + disclaimer
--     via the stored win's prize_id (NOT snapshots) — so they always reflect
--     the latest admin edit. Null if the prize was since deleted (prize_id ->
--     set null).
--
-- WHAT DOES NOT CHANGE:
--   * No columns added to secret_score_wins (current values, not snapshots).
--   * All win/idempotency/cap/rotation/security logic identical to 011.
--   * prize_name stays a snapshot (frozen at draw time).
--   * The edge function passes the RPC JSON through verbatim, so both new fields
--     flow to the guest with no edge-function change.
--
-- CREATE OR REPLACE FUNCTION preserves ownership + grants. Apply as the SAME
-- privileged (definer-owner) role used for 011 so the SECURITY DEFINER function
-- keeps bypassing RLS on the secret tables. Grants re-affirmed at the end.
-- =====================================================================

begin;

create or replace function scorecard.evaluate_secret_score(p_game_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = scorecard, public
as $$
declare
  v_loc            uuid;
  v_scores         jsonb;
  v_enabled        boolean;
  v_cap            int;
  v_reveal         text;
  v_pool_mode      text;
  v_holes          int[];
  v_scores_cfg     int[];
  v_hole           int;
  v_score          int;
  v_match          boolean;
  v_midnight       timestamptz;
  v_today_wins     int;
  v_prize_id       uuid;
  v_prize_name     text;
  v_prize_image    text;                           -- NEW: current prize image_url
  v_prize_disc     text;                           -- NEW: current prize disclaimer
  v_code           text;
  v_win            scorecard.secret_score_wins%rowtype;
  v_next_hole      int;
  v_next_score     int;
  i                int;
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
    -- prize_image + prize_disclaimer are the prize's CURRENT values (live
    -- lookup via prize_id), not snapshots.
    select * into v_win
      from scorecard.secret_score_wins
     where game_id = p_game_id;
    if found then
      return jsonb_build_object(
        'won', true,
        'prize_name', v_win.prize_name_snapshot,
        'prize_image', (select image_url
                          from scorecard.secret_score_prizes
                         where id = v_win.prize_id),
        'prize_disclaimer', (select disclaimer
                               from scorecard.secret_score_prizes
                              where id = v_win.prize_id),
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
  --     Also grab the prize's current image_url + disclaimer to return.
  select p.id, p.name, p.image_url, p.disclaimer
    into v_prize_id, v_prize_name, v_prize_image, v_prize_disc
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
    raise log 'secret_score: win recorded for game % at location % but draw pool empty (pool_mode=%) — secret left in place, NOT rotated',
      p_game_id, v_loc, v_pool_mode;
  end if;

  return jsonb_build_object(
    'won', true,
    'prize_name', v_prize_name,
    'prize_image', v_prize_image,
    'prize_disclaimer', v_prize_disc,
    'reveal_text', v_reveal,
    'redeem_code', v_code);
end;
$$;

-- Re-affirm execution grants (CREATE OR REPLACE preserves them; explicit here).
revoke all on function scorecard.evaluate_secret_score(uuid) from public;
grant execute on function scorecard.evaluate_secret_score(uuid) to anon, authenticated;

commit;

-- Rollback (manual): re-apply migration 011's version of the function (drops the
-- prize_image + prize_disclaimer fields). No data changes to undo.
