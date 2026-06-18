-- Migration 018: difficulty-tiered Secret Score prizes.
-- Adds a `tier` (standard|premium) to prizes; the engine picks the tier from the
-- won hole's difficulty (hole-in-one OR 2+ under par => premium) and draws from
-- that tier's pool. Empty-tier fallback: if the chosen tier has no active prize,
-- draw from the FULL active pool (preserves today's award rate until premium is
-- populated). Built from the LIVE evaluate_secret_score (no lazy-seed; matches
-- deployed behavior). Apply in Supabase SQL Editor as the privileged role.

-- 1. Tier column on the prize pool (existing rows default to 'standard').
alter table scorecard.secret_score_prizes
  add column if not exists tier text not null default 'standard'
    check (tier in ('standard','premium'));

create index if not exists secret_score_prizes_loc_tier_idx
  on scorecard.secret_score_prizes(location_id, tier, is_active);

-- 2. Tier-aware engine. Identical to the live function EXCEPT the three TIER changes.
create or replace function scorecard.evaluate_secret_score(p_game_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'scorecard', 'public'
as $function$
declare
  v_loc            uuid;
  v_scores         jsonb;
  v_pars           int[];                          -- TIER: won hole's pars (as played)
  v_enabled        boolean;
  v_cap            int;
  v_reveal         text;
  v_pool_mode      text;
  v_holes          int[];
  v_scores_cfg     int[];
  v_hole           int;
  v_score          int;
  v_par            int;                             -- TIER: par of the won hole
  v_tier           text;                            -- TIER: 'premium' | 'standard'
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
  -- (1) Elect the sole first-evaluator. Only completed, non-test rounds qualify.
  update scorecard.games g
     set secret_evaluated = true
   where g.id = p_game_id
     and g.status = 'completed'
     and g.is_test = false
     and g.secret_evaluated = false
  returning g.location_id, g.scores, g.pars_snapshot     -- TIER: also grab pars
       into v_loc, v_scores, v_pars;                     -- TIER: into v_pars

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
        'redeem_code', v_win.redeem_code);
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

  -- TIER: difficulty of the won secret. pars_snapshot is 1-based (matches v_hole).
  -- Hole-in-one is ALWAYS premium; otherwise premium when 2+ under par.
  -- Null/absent par => standard (defensive).
  v_par := v_pars[v_hole];
  v_tier := case
              when v_score = 1 then 'premium'
              when v_par is not null and v_score <= v_par - 2 then 'premium'
              else 'standard'
            end;

  -- (5) Weighted-random prize draw (Efraimidis-Spirakis) from the TIER's active
  -- prizes. TIER: if that tier has no eligible prize, fall back to the FULL active
  -- pool (preserves the pre-tiering award rate until the tier is populated).
  select p.id, p.name, p.image_url, p.disclaimer
    into v_prize_id, v_prize_name, v_prize_image, v_prize_disc
    from scorecard.secret_score_prizes p
   where p.location_id = v_loc and p.is_active and p.weight > 0
     and p.tier = v_tier                                  -- TIER: tier filter
   order by -ln(random()) / p.weight
   limit 1;

  if v_prize_id is null then                              -- TIER: empty-tier fallback
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
    'redeem_code', v_code);
end;
$function$;

-- Re-affirm grants (CREATE OR REPLACE preserves them, but explicit per the pattern).
revoke all on function scorecard.evaluate_secret_score(uuid) from public;
grant execute on function scorecard.evaluate_secret_score(uuid) to anon, authenticated;
