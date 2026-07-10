-- ═══════════════════════════════════════════════════════════════
-- 038_scorecard_winner_and_origin_display.sql
-- Display plumbing for winner-name (037) and secret-origin (035):
--   1. list_today_wins    — + winner_name (DROP+recreate, shape change)
--   2. list_recent_wins   — + winner_name (DROP+recreate, shape change)
--   3. get_current_secret — + source, drawn_by_name (definer profile join)
--   4. list_current_secrets (NEW) — admin-strip RPC: all accessible
--      locations' secrets incl. source + resolved drawn_by_name,
--      gated redeem_secret_score + per-row gz_can_access_location.
-- New columns appended LAST per convention. Grants re-applied after
-- each DROP (verified live: revoke public, grant anon+authenticated).
-- ═══════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────
-- 1. list_today_wins + winner_name
-- ───────────────────────────────────────────────────────────
drop function if exists scorecard.list_today_wins(uuid, text);

CREATE FUNCTION scorecard.list_today_wins(p_location_id uuid, p_passphrase text)
 RETURNS TABLE(id uuid, hole integer, score integer, prize_name_snapshot text, prize_image_url text, redeem_code text, redeemed boolean, redeemed_at timestamp with time zone, created_at timestamp with time zone, winner_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'scorecard', 'public'
AS $function$
begin
  if not scorecard._redemption_passphrase_ok(p_location_id, p_passphrase) then
    return;
  end if;
  return query
    select w.id, w.hole, w.score, w.prize_name_snapshot,
           p.image_url,
           w.redeem_code, w.redeemed, w.redeemed_at, w.created_at,
           w.winner_name
    from scorecard.secret_score_wins w
    left join scorecard.secret_score_prizes p on p.id = w.prize_id
    where w.location_id = p_location_id
      and w.created_at >= (date_trunc('day', now() at time zone 'America/Toronto')
                             at time zone 'America/Toronto')
    order by w.created_at desc;
end;
$function$;

revoke all on function scorecard.list_today_wins(uuid, text) from public;
grant execute on function scorecard.list_today_wins(uuid, text) to anon, authenticated;

-- ───────────────────────────────────────────────────────────
-- 2. list_recent_wins + winner_name (034 body preserved verbatim)
-- ───────────────────────────────────────────────────────────
drop function if exists scorecard.list_recent_wins(uuid, text, integer);

CREATE FUNCTION scorecard.list_recent_wins(p_location_id uuid, p_passphrase text, p_days integer DEFAULT 7)
 RETURNS TABLE(id uuid, hole integer, score integer, prize_name_snapshot text, prize_image_url text, redeem_code text, redeemed boolean, redeemed_at timestamp with time zone, created_at timestamp with time zone, location_id uuid, winner_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'scorecard', 'public'
AS $function$
declare
  v_days int;
begin
  v_days := greatest(1, least(coalesce(p_days, 7), 90));
  if p_location_id is null then
    if not scorecard.has_capability('redeem_secret_score') then
      return;
    end if;
    return query
      select w.id, w.hole, w.score, w.prize_name_snapshot,
             p.image_url,
             w.redeem_code, w.redeemed, w.redeemed_at, w.created_at,
             w.location_id,
             w.winner_name
      from scorecard.secret_score_wins w
      left join scorecard.secret_score_prizes p on p.id = w.prize_id
      where gz360_auth.gz_can_access_location(w.location_id)
        and w.created_at >= (
              date_trunc('day', now() at time zone 'America/Toronto')
                at time zone 'America/Toronto'
            ) - make_interval(days => v_days - 1)
      order by w.created_at desc
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
    select w.id, w.hole, w.score, w.prize_name_snapshot,
           p.image_url,
           w.redeem_code, w.redeemed, w.redeemed_at, w.created_at,
           w.location_id,
           w.winner_name
    from scorecard.secret_score_wins w
    left join scorecard.secret_score_prizes p on p.id = w.prize_id
    where w.location_id = p_location_id
      and w.created_at >= (
            date_trunc('day', now() at time zone 'America/Toronto')
              at time zone 'America/Toronto'
          ) - make_interval(days => v_days - 1)
    order by w.created_at desc
    limit 500;
end;
$function$;

revoke all on function scorecard.list_recent_wins(uuid, text, integer) from public;
grant execute on function scorecard.list_recent_wins(uuid, text, integer) to anon, authenticated;

-- ───────────────────────────────────────────────────────────
-- 3. get_current_secret + source + drawn_by_name
--    (returns jsonb — no shape change, plain CREATE OR REPLACE,
--     grants untouched; passphrase gate unchanged)
-- ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION scorecard.get_current_secret(p_location_id uuid, p_passphrase text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'scorecard', 'public'
AS $function$
declare
  v_hole     int;
  v_score    int;
  v_drawn_at timestamptz;
  v_source   text;   -- [038] 'auto' | 'admin_refresh' | 'desk_refresh' | null (pre-035 = auto)
  v_drawn_by uuid;   -- [038]
  v_name     text;   -- [038] resolved definer-side; anon never touches profiles
begin
  if not scorecard._redemption_passphrase_ok(p_location_id, p_passphrase) then
    return jsonb_build_object('ok', false);
  end if;

  select cur.hole, cur.score, cur.drawn_at, cur.source, cur.drawn_by
    into v_hole, v_score, v_drawn_at, v_source, v_drawn_by
    from scorecard.secret_score_current cur
   where cur.location_id = p_location_id;

  if not found then
    return jsonb_build_object('ok', true, 'has_secret', false);
  end if;

  if v_drawn_by is not null then
    select coalesce(pr.preferred_name, pr.name)
      into v_name
      from public.profiles pr
     where pr.id = v_drawn_by;
  end if;

  return jsonb_build_object(
    'ok', true,
    'has_secret', true,
    'hole', v_hole,
    'score', v_score,
    'drawn_at', v_drawn_at,
    'source', v_source,
    'drawn_by_name', v_name);
end;
$function$;

-- ───────────────────────────────────────────────────────────
-- 4. list_current_secrets (NEW) — for the admin Redemptions strip.
--    Authenticated-only; capability + per-row location gate,
--    mirroring list_recent_wins' all-locations mode.
-- ───────────────────────────────────────────────────────────
CREATE FUNCTION scorecard.list_current_secrets()
 RETURNS TABLE(location_id uuid, hole integer, score integer, drawn_at timestamp with time zone, source text, drawn_by_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'scorecard', 'public'
AS $function$
begin
  if not scorecard.has_capability('redeem_secret_score') then
    return;
  end if;
  return query
    select cur.location_id, cur.hole, cur.score, cur.drawn_at,
           cur.source,
           coalesce(pr.preferred_name, pr.name)
      from scorecard.secret_score_current cur
      left join public.profiles pr on pr.id = cur.drawn_by
     where gz360_auth.gz_can_access_location(cur.location_id);
end;
$function$;

revoke all on function scorecard.list_current_secrets() from public;
grant execute on function scorecard.list_current_secrets() to authenticated;
