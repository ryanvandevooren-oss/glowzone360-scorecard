-- Migration 027: Secret Score win-reveal enrichment.
-- Adds secret_hole + secret_score to the WIN responses of evaluate_secret_score
-- so the guest's glowing win reveal can show "Hole {hole} in {score} strokes —
-- perfect!". Rebuilt verbatim from the LIVE pg_get_functiondef (migration 022
-- body with the master kill-switch) — the ONLY changes are the two added jsonb
-- keys in the two win-return branches:
--   * re-return branch (already-evaluated game): secret_hole=v_win.hole,
--     secret_score=v_win.score (read from the stored secret_score_wins row)
--   * fresh-win branch: secret_hole=v_hole, secret_score=v_score
-- SAFETY: in the fresh-win branch the secret is rotated to a NEW hole/score
-- (update secret_score_current) BEFORE this return, so the returned values are
-- the just-CONSUMED secret, never the live one. The re-return branch is a game
-- that already won. All lose branches stay bare {won:false} — the secret never
-- leaks on a loss (it doesn't rotate on loss). Edge function unchanged (passes
-- the RPC JSON through). Apply in the Supabase SQL Editor as the privileged role.

create or replace function scorecard.evaluate_secret_score(p_game_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'scorecard', 'public'
as $function$
declare
  v_master         boolean;                         -- MASTER: global kill-switch
  v_loc            uuid;
  v_scores         jsonb;
  v_pars           int[];
  v_enabled        boolean;
  v_cap            int;
  v_reveal         text;
  v_pool_mode      text;
  v_holes          int[];
  v_scores_cfg     int[];
  v_hole           int;
  v_score          int;
  v_par            int;
  v_tier           text;
  v_match          boolean;
  v_midnight       timestamptz;
  v_today_wins     int;
  v_prize_id       uuid;
  v_prize_name     text;
  v_prize_image    text;
  v_prize_disc     text;
  v_code           text;
  v_win            scorecard.secret_score_wins%rowtype;
  v_next_hole      int;
  v_next_score     int;
  i                int;
begin
  -- MASTER kill-switch: if the company-wide secret_score_enabled flag is explicitly
  -- false, suppress everything (no evaluation, award, rotation, or re-return) before
  -- touching the game row. Fail-open — a null/missing row leaves the feature ON.
  select secret_score_enabled into v_master
    from scorecard.global_settings where id;
  if v_master is false then
    return jsonb_build_object('won', false);
  end if;

  -- (1) Elect the sole first-evaluator. Only completed, non-test rounds qualify.
  update scorecard.games g
     set secret_evaluated = true
   where g.id = p_game_id
     and g.status = 'completed'
     and g.is_test = false
     and g.secret_evaluated = false
  returning g.location_id, g.scores, g.pars_snapshot
       into v_loc, v_scores, v_pars;

  if not found then
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
        'redeem_code', v_win.redeem_code,
        'secret_hole', v_win.hole,
        'secret_score', v_win.score);
    end if;
    return jsonb_build_object('won', false);
  end if;

  perform pg_advisory_xact_lock(hashtext(v_loc::text));

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
    return jsonb_build_object('won', false);
  end if;

  select exists (
    select 1
      from jsonb_array_elements(v_scores) as t(arr)
     where (t.arr ->> (v_hole - 1))::int = v_score
  ) into v_match;

  if not v_match then
    return jsonb_build_object('won', false);
  end if;

  if v_cap is not null then
    v_midnight := date_trunc('day', now() at time zone 'America/Toronto')
                    at time zone 'America/Toronto';
    select count(*) into v_today_wins
      from scorecard.secret_score_wins
     where location_id = v_loc
       and created_at >= v_midnight;
    if v_today_wins >= v_cap then
      return jsonb_build_object('won', false);
    end if;
  end if;

  v_par := v_pars[v_hole];
  v_tier := case
              when v_score = 1 then 'premium'
              when v_par is not null and v_score <= v_par - 2 then 'premium'
              else 'standard'
            end;

  select p.id, p.name, p.image_url, p.disclaimer
    into v_prize_id, v_prize_name, v_prize_image, v_prize_disc
    from scorecard.secret_score_prizes p
   where p.location_id = v_loc and p.is_active and p.weight > 0
     and p.tier = v_tier
   order by -ln(random()) / p.weight
   limit 1;

  if v_prize_id is null then
    select p.id, p.name, p.image_url, p.disclaimer
      into v_prize_id, v_prize_name, v_prize_image, v_prize_disc
      from scorecard.secret_score_prizes p
     where p.location_id = v_loc and p.is_active and p.weight > 0
     order by -ln(random()) / p.weight
     limit 1;
  end if;

  if v_prize_id is null then
    return jsonb_build_object('won', false);
  end if;

  for i in 1..12 loop
    begin
      v_code := scorecard.gen_redeem_code();
      insert into scorecard.secret_score_wins(
        location_id, game_id, hole, score, prize_id, prize_name_snapshot, redeem_code)
      values (v_loc, p_game_id, v_hole, v_score, v_prize_id, v_prize_name, v_code);
      exit;
    exception when unique_violation then
      if i = 12 then raise; end if;
    end;
  end loop;

  update scorecard.games set won_prize = true where id = p_game_id;

  if v_pool_mode = 'random' then
    if coalesce(array_length(v_holes, 1), 0) > 0
       and coalesce(array_length(v_scores_cfg, 1), 0) > 0 then
      v_next_hole  := v_holes[1 + floor(random() * array_length(v_holes, 1))::int];
      v_next_score := v_scores_cfg[1 + floor(random() * array_length(v_scores_cfg, 1))::int];
    end if;
  else
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
    'redeem_code', v_code,
    'secret_hole', v_hole,
    'secret_score', v_score);
end;
$function$;
