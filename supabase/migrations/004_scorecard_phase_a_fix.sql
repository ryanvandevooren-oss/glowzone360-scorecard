-- =====================================================================
-- GlowZone 360 Scorecard — Phase A FIX (004)
-- Run AFTER scorecard_phase_a.sql, scorecard_phase_a_rls.sql, and
-- 003_scorecard_phase_a_seed.sql.
--
-- WHY THIS PATCH EXISTS
-- ---------------------------------------------------------------------
-- The anon INSERT policies on scorecard.games and scorecard.feedback
-- gate inserts on location visibility with a subquery against
-- scorecard.location_settings:
--     ... and exists (select 1 from scorecard.location_settings ls
--                     where ls.location_id = <row>.location_id
--                       and ls.scorecard_status in ('active','coming_soon'))
-- But scorecard_phase_a_rls.sql line ~108 does:
--     revoke all on scorecard.location_settings from anon;
-- RLS policy expressions run with the *querying* role's privileges, so an
-- anon INSERT evaluates that subquery as anon — which has no rights on
-- location_settings — and fails with:
--     ERROR 42501: permission denied for table location_settings
-- Net effect: real public visitors could NOT submit a game or feedback.
-- (Confirmed by the go-live anon-key test: checks 8 & 9 failed.)
--
-- THE FIX (keeps location_settings fully hidden from anon)
-- ---------------------------------------------------------------------
-- Introduce a SECURITY DEFINER helper, scorecard.is_location_visible(uuid),
-- owned by the (privileged) migration role. Because it is SECURITY DEFINER
-- it reads location_settings with the owner's privileges, never anon's, so
-- anon still gets NO table access to location_settings. The INSERT policies
-- then call the helper instead of the direct subquery.
-- This mirrors the existing scorecard.has_capability() helper and the
-- security_invoker=false views.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. SECURITY DEFINER visibility helper
--    Returns true when the location's scorecard is 'active' or
--    'coming_soon'. Runs as the function owner (the migration role), so
--    anon needs no privileges on scorecard.location_settings.
-- ---------------------------------------------------------------------
create or replace function scorecard.is_location_visible(loc uuid)
returns boolean
language sql
stable
security definer
set search_path = scorecard, public as $$
  select exists (
    select 1
    from scorecard.location_settings ls
    where ls.location_id = loc
      and ls.scorecard_status in ('active','coming_soon')
  );
$$;

-- Guests (and staff) may call the helper; they still cannot read the table.
grant execute on function scorecard.is_location_visible(uuid) to anon, authenticated;

-- Belt-and-suspenders: confirm anon still has NO access to the base table.
-- (Already revoked in scorecard_phase_a_rls.sql; restated here for clarity.)
revoke all on scorecard.location_settings from anon;

-- ---------------------------------------------------------------------
-- 2. Rewrite the anon INSERT policies to use the helper
--    (drop + recreate; predicate is otherwise identical to the original)
-- ---------------------------------------------------------------------

-- games: anon may INSERT a finished/abandoned game for a VISIBLE location
-- only, and may NOT self-declare a prize win (won_prize must be false).
drop policy if exists anon_insert_games on scorecard.games;
create policy anon_insert_games on scorecard.games
  for insert to anon
  with check (
    won_prize = false
    and scorecard.is_location_visible(location_id)
  );

-- feedback: anon may INSERT a 1-5 star rating for a VISIBLE location.
drop policy if exists anon_insert_feedback on scorecard.feedback;
create policy anon_insert_feedback on scorecard.feedback
  for insert to anon
  with check (
    stars between 1 and 5
    and scorecard.is_location_visible(location_id)
  );

-- NOTE: the anon_insert_newsletter policy is unaffected (it only checks
-- consent = true and never touches location_settings), so it is left as-is.

commit;

-- =====================================================================
-- RE-RUN THE GO-LIVE ANON-KEY TEST after applying this patch.
-- Expected results with ONLY the anon key:
--   Group 1 (still DENIED): select games/newsletter_signups/
--     secret_prize_state/feedback -> permission denied; select public.profiles
--     -> 0 rows; update/delete any scorecard row -> permission denied.
--   Group 2 (now SUCCEED):
--     select scorecard.public_locations -> 200 (3 visible locations)
--     insert scorecard.games (won_prize=false, visible location)  -> 201
--     insert scorecard.feedback (stars 1-5, visible location)     -> 201
--   And still DENIED (helper enforces visibility):
--     insert into games/feedback for a 'hidden' location -> blocked by RLS.
-- =====================================================================
