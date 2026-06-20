-- Migration 022: company-wide MASTER kill-switches for Secret Score & Promotions.
-- Two boolean flags on global_settings (default true → nothing changes until
-- flipped). Secret Score is gated in the engine (top guard); Promotions is gated
-- in the public_promotions view (per-branch filter). Both FAIL-OPEN: only an
-- explicit false suppresses; a null/missing row leaves the feature ON. Per-location
-- settings are untouched and resume when a master flips back to true. Built from
-- the LIVE engine + view definitions. Apply in the Supabase SQL Editor as the
-- privileged role.

-- ── Part 1: the two master flag columns (backfill existing singleton to true) ──
alter table scorecard.global_settings
  add column if not exists secret_score_enabled boolean not null default true;
alter table scorecard.global_settings
  add column if not exists promotions_enabled boolean not null default true;

-- ── Part 2: engine guard — evaluate_secret_score rebuilt from the LIVE body with a
--    top guard reading secret_score_enabled; returns {won:false} when explicitly
--    false, BEFORE the idempotency election (suppresses fresh wins AND re-returns).
--    Fail-open: null/missing row leaves the feature ON. ──
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
    'redeem_code', v_code);
end;
$function$;

revoke all on function scorecard.evaluate_secret_score(uuid) from public;
grant execute on function scorecard.evaluate_secret_score(uuid) to anon, authenticated;

-- ── Part 3: public_promotions view — identical to the LIVE 3-branch definition,
--    each branch's WHERE gaining a fail-open global promotions_enabled check. ──
create or replace view scorecard.public_promotions as
  select p.id, p.title, p.body, p.image_url, p.link_url, p.type, p.scope,
         p.location_id, p.promo_code, p.show_on_welcome, p.show_on_winner
    from scorecard.promotions p
   where p.is_active
     and (p.starts_at is null or p.starts_at <= now())
     and (p.ends_at is null or p.ends_at >= now())
     and p.scope = 'global'::text
     and coalesce((select g.promotions_enabled from scorecard.global_settings g where g.id), true)
  union all
  select p.id, p.title, p.body, p.image_url, p.link_url, p.type, p.scope,
         p.location_id, p.promo_code, p.show_on_welcome, p.show_on_winner
    from scorecard.promotions p
    join scorecard.location_settings ls on ls.location_id = p.location_id
   where p.is_active
     and (p.starts_at is null or p.starts_at <= now())
     and (p.ends_at is null or p.ends_at >= now())
     and p.scope = 'location'::text
     and (ls.scorecard_status = any (array['active'::text, 'coming_soon'::text]))
     and coalesce((select g.promotions_enabled from scorecard.global_settings g where g.id), true)
  union all
  select p.id, p.title, p.body, p.image_url, p.link_url, p.type, p.scope,
         pl.location_id, p.promo_code, p.show_on_welcome, p.show_on_winner
    from scorecard.promotions p
    join scorecard.promotion_locations pl on pl.promotion_id = p.id and pl.is_active = true
    join scorecard.location_settings ls on ls.location_id = pl.location_id
   where p.is_active
     and (p.starts_at is null or p.starts_at <= now())
     and (p.ends_at is null or p.ends_at >= now())
     and p.scope = 'multi'::text
     and (ls.scorecard_status = any (array['active'::text, 'coming_soon'::text]))
     and coalesce((select g.promotions_enabled from scorecard.global_settings g where g.id), true);
