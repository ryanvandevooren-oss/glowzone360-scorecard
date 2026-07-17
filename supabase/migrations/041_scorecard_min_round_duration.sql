-- ═══════════════════════════════════════════════════════════════
-- 041_scorecard_min_round_duration.sql
-- Anti-abuse: rounds faster than a per-location minimum duration
-- are silently ineligible for Secret Score wins (guest sees the
-- normal lose screen). Closes the lobby speed-fill exploit
-- (18 holes entered in ~30s, all-aces card matches any score-1
-- secret). Default 1200s = 20 minutes; per-location tunable in
-- secret_score_config.min_round_seconds (0 disables the gate).
-- Engine change: [041] markers; body otherwise = live 037 def.
-- Note: games.duration_seconds is a GENERATED column (finished_at
-- - started_at), so it cannot be spoofed by the client; the
-- engine's coalesce fallback is therefore redundant but harmless.
-- ═══════════════════════════════════════════════════════════════

alter table scorecard.secret_score_config
  add column if not exists min_round_seconds integer not null default 1200;

CREATE OR REPLACE FUNCTION scorecard.evaluate_secret_score(p_game_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'scorecard', 'public'
AS $function$
declare
  v_master         boolean;
  v_loc            uuid;
  v_scores         jsonb;
  v_pars           int[];
  v_names          jsonb;
  v_duration       int;     -- [041] round length in seconds
  v_min            int;     -- [041] per-location minimum
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
  v_match_count    int;
  v_winner_name    text;
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
  select secret_score_enabled into v_master
    from scorecard.global_settings where id;
  if v_master is false then
    return jsonb_build_object('won', false);
  end if;

  update scorecard.games g
     set secret_evaluated = true
   where g.id = p_game_id
     and g.status = 'completed'
     and g.is_test = false
     and g.secret_evaluated = false
  returning g.location_id, g.scores, g.pars_snapshot, g.player_names,
            coalesce(g.duration_seconds,
                     extract(epoch from (g.finished_at - g.started_at))::int)  -- [041]
       into v_loc, v_scores, v_pars, v_names, v_duration;

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
        'winner_name', v_win.winner_name,
        'secret_hole', v_win.hole,
        'secret_score', v_win.score);
    end if;
    return jsonb_build_object('won', false);
  end if;

  perform pg_advisory_xact_lock(hashtext(v_loc::text));

  select sc.enabled, sc.daily_win_cap, sc.win_reveal_text,
         sc.pool_mode, sc.allowed_holes, sc.allowed_scores,
         sc.min_round_seconds                                   -- [041]
    into v_enabled, v_cap, v_reveal, v_pool_mode, v_holes, v_scores_cfg,
         v_min                                                  -- [041]
    from scorecard.secret_score_config sc
   where sc.location_id = v_loc;

  if not found or v_enabled is distinct from true then
    return jsonb_build_object('won', false);
  end if;

  -- [041] Speed-fill gate: too-fast (or unmeasurable) rounds are
  -- silently ineligible. v_min = 0 disables the gate.
  if coalesce(v_min, 0) > 0
     and (v_duration is null or v_duration < v_min) then
    return jsonb_build_object('won', false);
  end if;

  select cur.hole, cur.score
    into v_hole, v_score
    from scorecard.secret_score_current cur
   where cur.location_id = v_loc;

  if not found then
    return jsonb_build_object('won', false);
  end if;

  select count(*),
         string_agg(m.nm, ' & ' order by m.idx)
    into v_match_count, v_winner_name
    from (
      select t.idx,
             nullif(left(btrim(v_names ->> (t.idx - 1)::int), 40), '') as nm
        from jsonb_array_elements(v_scores) with ordinality as t(arr, idx)
       where (t.arr ->> (v_hole - 1))::int = v_score
    ) m;

  v_match := coalesce(v_match_count, 0) > 0;

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
        location_id, game_id, hole, score, prize_id,
        prize_name_snapshot, redeem_code, winner_name)
      values (v_loc, p_game_id, v_hole, v_score, v_prize_id,
              v_prize_name, v_code, v_winner_name);
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
       set hole = v_next_hole, score = v_next_score, drawn_at = now(),
           source = 'auto', drawn_by = null
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
    'winner_name', v_winner_name,
    'secret_hole', v_hole,
    'secret_score', v_score);
end;
$function$;
