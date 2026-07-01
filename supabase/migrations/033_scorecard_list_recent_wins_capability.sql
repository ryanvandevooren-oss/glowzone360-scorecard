-- ═══════════════════════════════════════════════════════════════════════
--   033_scorecard_list_recent_wins_capability.sql
--   Widens the GATE of list_recent_wins so the admin (authenticated, no
--   passphrase) can call the SAME function as /redeem — one source of truth.
--
--   UNCHANGED: the entire query body (window math, joins, ordering, 500 cap)
--   and the passphrase path. A caller with a valid passphrase behaves EXACTLY
--   as before (the passphrase check runs first, identical to 032).
--
--   ADDED: if the passphrase does NOT pass, fall through to a capability
--   check — an authenticated user with redeem_secret_score AND access to the
--   location may proceed. If neither passes, return nothing (leak-free).
--
--   /redeem keeps passing its passphrase (unchanged). The admin passes an
--   empty-string passphrase and authorizes via capability.
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
  -- AUTH: passphrase path first (unchanged from 032), else capability path.
  if not scorecard._redemption_passphrase_ok(p_location_id, p_passphrase) then
    -- No valid passphrase — allow an authenticated, capable, location-scoped
    -- caller (the admin). Both checks required; either failing → return nothing.
    if not (
         scorecard.has_capability('redeem_secret_score')
         and gz360_auth.gz_can_access_location(p_location_id)
       ) then
      return;
    end if;
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
--   GRANTS unchanged from 032 (anon, authenticated). Re-stated so the file
--   is self-contained.
-- ═══════════════════════════════════════════════════════════════════════

revoke all     on function scorecard.list_recent_wins(uuid, text, int) from public;
grant  execute on function scorecard.list_recent_wins(uuid, text, int) to anon, authenticated;
