-- ═══════════════════════════════════════════════════════════════════════
--   034_scorecard_list_recent_wins_multiloc.sql
--   Adds an ALL-LOCATIONS mode to list_recent_wins so the admin Redemptions
--   tab (which spans every location the user can access) can use the SAME
--   function as /redeem.
--
--   NOTE: requires DROP before CREATE because the return shape changes
--   (adds location_id as the last returned column). /redeem always passes a
--   concrete p_location_id, so its single-location behavior is unchanged; it
--   simply receives an extra location_id column it ignores.
--
--   p_location_id NULL  → ALL-LOCATIONS mode: capability required
--     (redeem_secret_score); per-location access enforced row-by-row via
--     gz_can_access_location. Global most-recent-500 across accessible locs.
--   p_location_id set   → SINGLE-LOCATION mode (unchanged): passphrase OR
--     (capability AND location access).
-- ═══════════════════════════════════════════════════════════════════════

drop function if exists scorecard.list_recent_wins(uuid, text, int);

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
  created_at          timestamptz,
  location_id         uuid
)
language plpgsql
stable
security definer
set search_path = scorecard, public
as $$
declare
  v_days int;
begin
  v_days := greatest(1, least(coalesce(p_days, 7), 90));

  if p_location_id is null then
    -- ── ALL-LOCATIONS MODE (admin) ──
    if not scorecard.has_capability('redeem_secret_score') then
      return;
    end if;

    return query
      select w.id, w.hole, w.score, w.prize_name_snapshot,
             p.image_url,
             w.redeem_code, w.redeemed, w.redeemed_at, w.created_at,
             w.location_id
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

  -- ── SINGLE-LOCATION MODE (unchanged: passphrase OR capability) ──
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
           w.location_id
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
--   GRANTS (anon, authenticated) — re-stated so the file is self-contained.
-- ═══════════════════════════════════════════════════════════════════════

revoke all     on function scorecard.list_recent_wins(uuid, text, int) from public;
grant  execute on function scorecard.list_recent_wins(uuid, text, int) to anon, authenticated;
