# GlowZone 360 Scorecard — Phase A Handoff (for Claude Code)

This package contains the Phase A database build for the scorecard app, to be
applied to the **existing Ops Hub Supabase project** (`qfwqdqlzzolyahjcqmka`).
It reuses the Hub's `public.locations`, `public.profiles`, `owner_locations`,
and the `gz360_auth.*` helper functions. It does **not** duplicate them.

## Files
1. `scorecard_phase_a.sql` — schema: a `scorecard` schema with 10 tables, a
   data-driven role-permission matrix, a capability helper, and two public
   read-only views for the anonymous guest app.
2. `scorecard_phase_a_rls.sql` — Row Level Security policies + grants. **Run
   this second.** Contains the go-live anon test checklist and edge-function
   notes at the bottom.

## How to apply
- Review both files against the live schema first (confirm `gz360_auth`
  helper names and `public.locations` / `public.profiles` columns match — they
  were taken from migrations 001/003/013/014).
- Apply as a new migration (e.g. `0XX_scorecard_phase_a.sql` then
  `0XX_scorecard_phase_a_rls.sql`) using the same migration workflow as the Hub.
- Then SEED: insert `scorecard.location_settings` rows for the real locations
  (plug in the actual location UUIDs from the slug→uuid query), set
  `scorecard_status` ('active' for Brampton/Mississauga, 'coming_soon' or
  'hidden' for Etobicoke), and seed `secret_prize_config` / `prize_pool` per
  location as desired.

## Key design points
- **Anonymous guests** only ever read the two views (`public_locations`,
  `public_promotions`) and may INSERT games / newsletter (consent=true) /
  feedback. They can read nothing else. Verify with the go-live test.
- **Staff** authenticate with their existing Ops Hub credentials (same
  Supabase auth). Capabilities are driven by `scorecard.role_permissions`
  (admin-editable) — nothing is hardcoded. Default lets team_member/
  team_leader/location_manager redeem prizes; admin can change this.
- **Secret-prize win evaluation** runs in a SERVICE-ROLE edge function only
  (not on the phone). `secret_prize_state` is unreadable by anon/staff via RLS.
- **Prizes are physical/instant**: the edge function creates a `prize_wins`
  row with a short code; staff confirm it (UPDATE status->confirmed) at the
  desk; no coupon is stored.

## Still needed before seeding
- The slug→uuid location map (run:
  `select legacy_id, id, name, status from public.locations order by sort_order, name;`)

## Next phases (not in this package)
- Phase B: wire the guest app to the views + inserts; add feedback + fun features.
- Phase C: staff admin app at admin.scorecard.glowzone360.com (shared SSO).
- Phase D: the submit_finish edge function (secret prize).
- Phase E: reporting (location-filterable).

---

## v2 corrections (after Claude Code review)
The following were fixed in the SQL after the first review pass:
- **Added `authenticated` GRANTs** — custom schemas don't inherit Supabase's
  public-schema auto-grants, so staff policies would have been moot. Now
  granted explicitly (schema usage + table privileges + default privileges).
- **Added anon INSERT GRANTs** on games/newsletter/feedback — the insert
  POLICIES existed but the underlying privilege was missing, so guest inserts
  would have failed. Fixed.
- **Schema exposure** — added a note: expose the `scorecard` schema to the API
  (Dashboard → Project Settings → API → Exposed schemas → add `scorecard`).
  Decided to expose (security comes from RLS+grants, not from hiding).
- **`public_promotions` view** now respects location visibility — promos for
  hidden locations are no longer enumerable by guests.
- **`anon_insert_games` tightened** — guests can only insert games for a
  visible location and CANNOT self-set `won_prize` (only the edge function
  sets that). Feedback inserts similarly scoped to visible locations.
- **Removed** the `revoke all on public.profiles from anon` line — we do not
  touch any Ops Hub object. Anon simply has no grant on profiles to begin with.

## Pre-apply verification (run read-only in Supabase first)
```sql
-- helper function signatures
select n.nspname, p.proname, pg_get_function_arguments(p.oid), pg_get_function_result(p.oid)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='gz360_auth'
  and p.proname in ('gz_is_admin','gz_can_access_location','gz_can_manage_location');

-- CRITICAL: actual stored role values must match the matrix exactly
select distinct role from public.profiles;
-- expect a subset of: admin, owner, location_manager, team_leader, team_member, game_tech
-- if casing/names differ, has_capability() returns false and staff writes fail closed.
```

## Apply order (after verification passes)
1. Expose `scorecard` schema to the API (dashboard, one-time).
2. `scorecard_phase_a.sql`  (schema)
3. `scorecard_phase_a_rls.sql`  (RLS + grants)
4. `003_scorecard_phase_a_seed.sql`  (seed with real UUIDs)
5. Run the go-live anon-key test (bottom of the RLS file) — all 6 must fail;
   the 3 allowed anon actions must succeed.
