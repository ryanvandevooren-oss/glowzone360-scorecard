-- ═══════════════════════════════════════════════════════════════════════
--   036_scorecard_secret_provenance_writers.sql
--   Populates secret_score_current.source + drawn_by on all write paths
--   (columns added in 035). Only changes vs the prior live bodies:
--     evaluate_secret_score    → rotation UPDATE sets source='auto', drawn_by=null
--     redraw_secret_score      → upsert sets source='admin_refresh', drawn_by=auth.uid()
--     refresh_secret_from_desk → upsert sets source='desk_refresh', drawn_by=auth.uid()
--   In the two manual fns, the v_actor_role/v_actor_uid assignments were moved
--   to BEFORE the upsert so drawn_by can reference v_actor_uid; the audit
--   insert into secret_score_redraws is unchanged.
--   No 'seed' path exists in the live engine (027 has no lazy-seed insert), so
--   the first secret at a location is created by whichever manual refresh runs
--   first (stamped admin_refresh / desk_refresh). Pre-existing rows stay
--   null/null → shown as "automatic".
--   Verified live before commit: an admin refresh stamped admin_refresh + the
--   actor's name (resolved via public.profiles).
-- ═══════════════════════════════════════════════════════════════════════

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
       set hole = v_next_hole, score = v_next_score, drawn_at = now(), source = 'auto', drawn_by = null
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

create or replace function scorecard.redraw_secret_score(p_location_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = scorecard, public
as $$
declare
  v_enabled    boolean;
  v_pool_mode  text;
  v_holes      int[];
  v_scores     int[];
  v_old_hole   int;
  v_old_score  int;
  v_new_hole   int;
  v_new_score  int;
  v_drawn_at   timestamptz;
  v_actor_role text;
  v_actor_uid  uuid;
  v_try        int;
begin
  -- (1) AUTHORIZE — same gate as a per-location config write. auth.uid() and the
  -- role helpers still reflect the CALLER inside a SECURITY DEFINER function.
  if not (scorecard.has_capability('configure_secret_score')
          and gz360_auth.gz_can_manage_location(p_location_id)) then
    raise exception 'not authorized to redraw the secret for location %', p_location_id
      using errcode = '42501';
  end if;

  -- (2) Load the location's pool config. Disabled / unconfigured → no redraw.
  select sc.enabled, sc.pool_mode, sc.allowed_holes, sc.allowed_scores
    into v_enabled, v_pool_mode, v_holes, v_scores
    from scorecard.secret_score_config sc
   where sc.location_id = p_location_id;

  if not found or v_enabled is distinct from true then
    return jsonb_build_object('ok', false, 'reason', 'disabled');
  end if;

  -- Serialize against the engine's win-rotation for this location (same lock key
  -- 011 uses) so a concurrent win and a manual redraw can't clobber each other.
  perform pg_advisory_xact_lock(hashtext(p_location_id::text));

  -- (3) Current secret, if any (null on a location that has never drawn).
  select cur.hole, cur.score
    into v_old_hole, v_old_score
    from scorecard.secret_score_current cur
   where cur.location_id = p_location_id;

  -- (4) Draw a NEW, DIFFERENT secret — REUSE draw_secret_score, up to 10 tries.
  for v_try in 1..10 loop
    select o_hole, o_score
      into v_new_hole, v_new_score
      from scorecard.draw_secret_score(p_location_id, v_pool_mode, v_holes, v_scores);

    if v_new_hole is null or v_new_score is null then
      -- Empty pool: nothing to draw. Do NOT write NULLs (columns are NOT NULL).
      return jsonb_build_object('ok', false, 'reason', 'empty_pool');
    end if;

    exit when v_old_hole is null
           or v_new_hole  <> v_old_hole
           or v_new_score <> v_old_score;
  end loop;

  -- Every draw equalled the current secret → pool too small to differ.
  if v_old_hole is not null
     and v_new_hole  = v_old_hole
     and v_new_score = v_old_score then
    return jsonb_build_object('ok', false, 'reason', 'pool_too_small');
  end if;

  -- Resolve actor BEFORE the upsert so drawn_by can reference v_actor_uid.
  v_actor_role := gz360_auth.gz_current_role();
  v_actor_uid  := auth.uid();

  -- (5) Write the new secret (insert-or-update the singleton row).
  insert into scorecard.secret_score_current (location_id, hole, score, drawn_at, source, drawn_by)
  values (p_location_id, v_new_hole, v_new_score, now(), 'admin_refresh', v_actor_uid)
  on conflict (location_id) do update
    set hole     = excluded.hole,
        score    = excluded.score,
        drawn_at = excluded.drawn_at,
        source   = excluded.source,
        drawn_by = excluded.drawn_by
  returning drawn_at into v_drawn_at;

  -- (6) Audit the redraw (old → new + actor).
  insert into scorecard.secret_score_redraws
    (location_id, actor_role, actor_uid, old_hole, old_score, new_hole, new_score)
  values
    (p_location_id, v_actor_role, v_actor_uid, v_old_hole, v_old_score, v_new_hole, v_new_score);

  -- (7) Hand the new secret back so the UI can refresh the live-secret banner.
  return jsonb_build_object(
    'ok',       true,
    'hole',     v_new_hole,
    'score',    v_new_score,
    'drawn_at', v_drawn_at);
end;
$$;

create or replace function scorecard.refresh_secret_from_desk(p_location_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = scorecard, public
as $$
declare
  v_enabled    boolean;
  v_pool_mode  text;
  v_holes      int[];
  v_scores     int[];
  v_old_hole   int;
  v_old_score  int;
  v_new_hole   int;
  v_new_score  int;
  v_drawn_at   timestamptz;
  v_actor_role text;
  v_actor_uid  uuid;
  v_try        int;
begin
  if not (scorecard.has_capability('override_secret_redemption')
          and gz360_auth.gz_can_access_location(p_location_id)) then
    raise exception 'not authorized to refresh the secret for location %', p_location_id
      using errcode = '42501';
  end if;

  select sc.enabled, sc.pool_mode, sc.allowed_holes, sc.allowed_scores
    into v_enabled, v_pool_mode, v_holes, v_scores
    from scorecard.secret_score_config sc
   where sc.location_id = p_location_id;
  if not found or v_enabled is distinct from true then
    return jsonb_build_object('ok', false, 'reason', 'disabled');
  end if;

  perform pg_advisory_xact_lock(hashtext(p_location_id::text));

  select cur.hole, cur.score into v_old_hole, v_old_score
    from scorecard.secret_score_current cur
   where cur.location_id = p_location_id;

  for v_try in 1..10 loop
    select o_hole, o_score into v_new_hole, v_new_score
      from scorecard.draw_secret_score(p_location_id, v_pool_mode, v_holes, v_scores);
    if v_new_hole is null or v_new_score is null then
      return jsonb_build_object('ok', false, 'reason', 'empty_pool');
    end if;
    exit when v_old_hole is null
           or v_new_hole  <> v_old_hole
           or v_new_score <> v_old_score;
  end loop;

  if v_old_hole is not null and v_new_hole = v_old_hole and v_new_score = v_old_score then
    return jsonb_build_object('ok', false, 'reason', 'pool_too_small');
  end if;

  v_actor_role := gz360_auth.gz_current_role();
  v_actor_uid  := auth.uid();
  insert into scorecard.secret_score_current (location_id, hole, score, drawn_at, source, drawn_by)
  values (p_location_id, v_new_hole, v_new_score, now(), 'desk_refresh', v_actor_uid)
  on conflict (location_id) do update
    set hole = excluded.hole, score = excluded.score, drawn_at = excluded.drawn_at,
        source = excluded.source, drawn_by = excluded.drawn_by
  returning drawn_at into v_drawn_at;

  insert into scorecard.secret_score_redraws
    (location_id, actor_role, actor_uid, old_hole, old_score, new_hole, new_score)
  values
    (p_location_id, v_actor_role, v_actor_uid, v_old_hole, v_old_score, v_new_hole, v_new_score);

  return jsonb_build_object('ok', true, 'hole', v_new_hole, 'score', v_new_score, 'drawn_at', v_drawn_at);
end;
$$;
