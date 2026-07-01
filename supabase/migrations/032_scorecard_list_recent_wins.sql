-- ═══════════════════════════════════════════════════════════════════════
--   032_scorecard_list_recent_wins.sql
--   Adds list_recent_wins(p_location_id, p_passphrase, p_days) — a windowed
--   sibling of list_today_wins for the /redeem History view.
--   - Same passphrase self-gate (_redemption_passphrase_ok)
--   - Same best-effort prize-image LEFT join
--   - Returns BOTH redeemed and unredeemed wins in the window
--   - Windowed by p_days back from Toronto midnight; ordered created_at desc
--   - p_days clamped (1..90); results capped at 500 rows as a safety net
-- ═══════════════════════════════════════════════════════════════════════

create or replace function scorecard.list_recent_wins(
  p_location_id uuid,
  p_passphrase  text,
  p_days        int default 7
)
returns table (
  id                  uuid,
  hole                int,
  score               int,
  prize_name_snapshot text,
  prize_image_url     text,
  redeem_code         text,
  redeemed            boolean,
  redeemed_at         timestamptz,
  created_at          timestamptz
)
language plpgsql
stable
security definer
set search_path = scorecard, public
as $$
declare
  v_days int;
begin
  if not scorecard._redemption_passphrase_ok(p_location_id, p_passphrase) then
    return;
  end if;

  -- clamp window: at least 1 day, at most 90 (safety ceiling)
  v_days := greatest(1, least(coalesce(p_days, 7), 90));

  return query
    select w.id, w.hole, w.score, w.prize_name_snapshot,
           p.image_url,
           w.redeem_code, w.redeemed, w.redeemed_at, w.created_at
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
$$;

-- ═══════════════════════════════════════════════════════════════════════
--   GRANTS  (mirror list_today_wins exactly)
-- ═══════════════════════════════════════════════════════════════════════

revoke all     on function scorecard.list_recent_wins(uuid, text, int) from public;
grant  execute on function scorecard.list_recent_wins(uuid, text, int) to anon, authenticated;
