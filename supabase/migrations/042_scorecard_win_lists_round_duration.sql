-- ═══════════════════════════════════════════════════════════════
-- 042_scorecard_win_lists_round_duration.sql
-- Add the winning round's duration (round_minutes, 1dp) to both
-- win-list RPCs so staff can sanity-check wins at the desk.
-- Shape change → DROP + recreate; column appended LAST; grants
-- re-applied (verified live: revoke public, anon+authenticated).
-- LEFT JOIN games so a win whose game row is missing still lists
-- (round_minutes null). Bodies otherwise = live 038 definitions.
-- ═══════════════════════════════════════════════════════════════

drop function if exists scorecard.list_today_wins(uuid, text);

CREATE FUNCTION scorecard.list_today_wins(p_location_id uuid, p_passphrase text)
 RETURNS TABLE(id uuid, hole integer, score integer, prize_name_snapshot text, prize_image_url text, redeem_code text, redeemed boolean, redeemed_at timestamp with time zone, created_at timestamp with time zone, winner_name text, round_minutes numeric)
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
           w.winner_name,
           round(g.duration_seconds / 60.0, 1)
    from scorecard.secret_score_wins w
    left join scorecard.secret_score_prizes p on p.id = w.prize_id
    left join scorecard.games g on g.id = w.game_id
    where w.location_id = p_location_id
      and w.created_at >= (date_trunc('day', now() at time zone 'America/Toronto')
                             at time zone 'America/Toronto')
    order by w.created_at desc;
end;
$function$;

revoke all on function scorecard.list_today_wins(uuid, text) from public;
grant execute on function scorecard.list_today_wins(uuid, text) to anon, authenticated;

drop function if exists scorecard.list_recent_wins(uuid, text, integer);

CREATE FUNCTION scorecard.list_recent_wins(p_location_id uuid, p_passphrase text, p_days integer DEFAULT 7)
 RETURNS TABLE(id uuid, hole integer, score integer, prize_name_snapshot text, prize_image_url text, redeem_code text, redeemed boolean, redeemed_at timestamp with time zone, created_at timestamp with time zone, location_id uuid, winner_name text, round_minutes numeric)
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
             w.winner_name,
             round(g.duration_seconds / 60.0, 1)
      from scorecard.secret_score_wins w
      left join scorecard.secret_score_prizes p on p.id = w.prize_id
      left join scorecard.games g on g.id = w.game_id
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
           w.winner_name,
           round(g.duration_seconds / 60.0, 1)
    from scorecard.secret_score_wins w
    left join scorecard.secret_score_prizes p on p.id = w.prize_id
    left join scorecard.games g on g.id = w.game_id
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
