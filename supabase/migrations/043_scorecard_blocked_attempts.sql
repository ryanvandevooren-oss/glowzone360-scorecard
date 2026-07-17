-- ═══════════════════════════════════════════════════════════════
-- 043_scorecard_blocked_attempts.sql
-- Visibility for gated speed-fill attempts. A round that MATCHES
-- the secret but fails the 041 minimum-duration gate is now
-- LOGGED instead of vanishing: no prize, no code, no rotation,
-- no cap impact; the guest still sees the plain lose screen.
-- Both win-list RPCs union the attempts in with a trailing
-- `blocked boolean` (appended last) so desk lists show ⛔ rows
-- in Today's Wins AND History.
--   1. secret_score_blocked_attempts (definer-written, locked)
--   2. evaluate_secret_score: the gate now fires AFTER the match
--      is computed (benign reordering — both paths still return
--      plain lose) so a gated match can be logged.  [043] markers
--   3. list_today_wins / list_recent_wins: DROP+recreate, union
--      attempts (blocked=true, null code, redeemed=false).
-- ═══════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────
-- 1. Attempts table — engine-written via definer; no client
--    access (RLS on, no policies, no grants — the list RPCs
--    read it definer-side).
-- ───────────────────────────────────────────────────────────
create table if not exists scorecard.secret_score_blocked_attempts (
  id            uuid primary key default gen_random_uuid(),
  location_id   uuid not null,
  game_id       uuid not null,
  hole          int  not null,
  score         int  not null,
  winner_name   text,
  round_seconds int,
  created_at    timestamptz not null default now()
);
alter table scorecard.secret_score_blocked_attempts enable row level security;
revoke all on scorecard.secret_score_blocked_attempts from anon, authenticated;

-- ───────────────────────────────────────────────────────────
-- 2. Engine
-- ───────────────────────────────────────────────────────────
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
  v_duration       int;
  v_min            int;
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
                     extract(epoch from (g.finished_at - g.started_at))::int)
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
         sc.min_round_seconds
    into v_enabled, v_cap, v_reveal, v_pool_mode, v_holes, v_scores_cfg,
         v_min
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

  -- [043] Speed-fill gate, now AFTER the match so a gated match
  -- is logged for desk visibility. No prize/code/rotation/cap
  -- impact; guest sees the plain lose screen. v_min = 0 disables.
  if coalesce(v_min, 0) > 0
     and (v_duration is null or v_duration < v_min) then
    insert into scorecard.secret_score_blocked_attempts
      (location_id, game_id, hole, score, winner_name, round_seconds)
    values (v_loc, p_game_id, v_hole, v_score, v_winner_name, v_duration);
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

-- ───────────────────────────────────────────────────────────
-- 3a. list_today_wins + blocked union
-- ───────────────────────────────────────────────────────────
drop function if exists scorecard.list_today_wins(uuid, text);

CREATE FUNCTION scorecard.list_today_wins(p_location_id uuid, p_passphrase text)
 RETURNS TABLE(id uuid, hole integer, score integer, prize_name_snapshot text, prize_image_url text, redeem_code text, redeemed boolean, redeemed_at timestamp with time zone, created_at timestamp with time zone, winner_name text, round_minutes numeric, blocked boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'scorecard', 'public'
AS $function$
declare
  v_midnight timestamptz;
begin
  if not scorecard._redemption_passphrase_ok(p_location_id, p_passphrase) then
    return;
  end if;
  v_midnight := date_trunc('day', now() at time zone 'America/Toronto')
                  at time zone 'America/Toronto';
  return query
    select * from (
      select w.id, w.hole, w.score, w.prize_name_snapshot,
             p.image_url as prize_image_url,
             w.redeem_code, w.redeemed, w.redeemed_at, w.created_at,
             w.winner_name,
             round(g.duration_seconds / 60.0, 1) as round_minutes,
             false as blocked
      from scorecard.secret_score_wins w
      left join scorecard.secret_score_prizes p on p.id = w.prize_id
      left join scorecard.games g on g.id = w.game_id
      where w.location_id = p_location_id
        and w.created_at >= v_midnight
      union all
      select a.id, a.hole, a.score,
             null::text, null::text, null::text,
             false, null::timestamptz, a.created_at,
             a.winner_name,
             round(a.round_seconds / 60.0, 1),
             true
      from scorecard.secret_score_blocked_attempts a
      where a.location_id = p_location_id
        and a.created_at >= v_midnight
    ) u
    order by u.created_at desc;
end;
$function$;

revoke all on function scorecard.list_today_wins(uuid, text) from public;
grant execute on function scorecard.list_today_wins(uuid, text) to anon, authenticated;

-- ───────────────────────────────────────────────────────────
-- 3b. list_recent_wins + blocked union (all three modes)
-- ───────────────────────────────────────────────────────────
drop function if exists scorecard.list_recent_wins(uuid, text, integer);

CREATE FUNCTION scorecard.list_recent_wins(p_location_id uuid, p_passphrase text, p_days integer DEFAULT 7)
 RETURNS TABLE(id uuid, hole integer, score integer, prize_name_snapshot text, prize_image_url text, redeem_code text, redeemed boolean, redeemed_at timestamp with time zone, created_at timestamp with time zone, location_id uuid, winner_name text, round_minutes numeric, blocked boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'scorecard', 'public'
AS $function$
declare
  v_days  int;
  v_since timestamptz;
begin
  v_days := greatest(1, least(coalesce(p_days, 7), 90));
  v_since := (date_trunc('day', now() at time zone 'America/Toronto')
                at time zone 'America/Toronto') - make_interval(days => v_days - 1);
  if p_location_id is null then
    if not scorecard.has_capability('redeem_secret_score') then
      return;
    end if;
    return query
      select * from (
        select w.id, w.hole, w.score, w.prize_name_snapshot,
               p.image_url as prize_image_url,
               w.redeem_code, w.redeemed, w.redeemed_at, w.created_at,
               w.location_id,
               w.winner_name,
               round(g.duration_seconds / 60.0, 1) as round_minutes,
               false as blocked
        from scorecard.secret_score_wins w
        left join scorecard.secret_score_prizes p on p.id = w.prize_id
        left join scorecard.games g on g.id = w.game_id
        where gz360_auth.gz_can_access_location(w.location_id)
          and w.created_at >= v_since
        union all
        select a.id, a.hole, a.score,
               null::text, null::text, null::text,
               false, null::timestamptz, a.created_at,
               a.location_id,
               a.winner_name,
               round(a.round_seconds / 60.0, 1),
               true
        from scorecard.secret_score_blocked_attempts a
        where gz360_auth.gz_can_access_location(a.location_id)
          and a.created_at >= v_since
      ) u
      order by u.created_at desc
      limit 500;
    return;
  end if;
  if not scorecard._redemption_passphrase_ok(p_location_id, p_passphrase) then
    if not (
         scorecard.has_capability('redeem_secret_score')
         and gz360_auth.gz_can_access_location(p_location_id)
       ) then
      return;
    end if;
  end if;
  return query
    select * from (
      select w.id, w.hole, w.score, w.prize_name_snapshot,
             p.image_url as prize_image_url,
             w.redeem_code, w.redeemed, w.redeemed_at, w.created_at,
             w.location_id,
             w.winner_name,
             round(g.duration_seconds / 60.0, 1) as round_minutes,
             false as blocked
      from scorecard.secret_score_wins w
      left join scorecard.secret_score_prizes p on p.id = w.prize_id
      left join scorecard.games g on g.id = w.game_id
      where w.location_id = p_location_id
        and w.created_at >= v_since
      union all
      select a.id, a.hole, a.score,
             null::text, null::text, null::text,
             false, null::timestamptz, a.created_at,
             a.location_id,
             a.winner_name,
             round(a.round_seconds / 60.0, 1),
             true
      from scorecard.secret_score_blocked_attempts a
      where a.location_id = p_location_id
        and a.created_at >= v_since
    ) u
    order by u.created_at desc
    limit 500;
end;
$function$;

revoke all on function scorecard.list_recent_wins(uuid, text, integer) from public;
grant execute on function scorecard.list_recent_wins(uuid, text, integer) to anon, authenticated;
