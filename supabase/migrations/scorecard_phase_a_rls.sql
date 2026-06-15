-- =====================================================================
-- GlowZone 360 Scorecard — Phase A RLS policies
-- Run AFTER scorecard_phase_a.sql.
--
-- Security model (mirrors Ops Hub):
--   * anon (public guest app)  -> deny by default; only the narrow grants below
--   * authenticated (staff)    -> gated by gz360_auth.* helpers + the
--                                 scorecard.role_permissions matrix
--   * all real WRITES for prize logic go through a service-role edge
--     function (bypasses RLS with the service key) — see notes at bottom.
--
-- NOTE: 'anon' = the public site's key; 'authenticated' = a logged-in staff
-- session shared with the Ops Hub (same Supabase project / auth.users).
-- =====================================================================

-- ---------------------------------------------------------------------
-- API EXPOSURE (do this once, outside SQL):
-- Expose the "scorecard" schema to the API so supabase-js can reach it.
--   Supabase Dashboard -> Project Settings -> API -> "Exposed schemas"
--   -> add: scorecard   (alongside public)
-- Security still comes from RLS + grants below, not from hiding the schema.
-- ---------------------------------------------------------------------

begin;

-- Enable RLS on every scorecard table (deny-all until policies added)
alter table scorecard.location_settings    enable row level security;
alter table scorecard.games                enable row level security;
alter table scorecard.newsletter_signups   enable row level security;
alter table scorecard.feedback             enable row level security;
alter table scorecard.promotions           enable row level security;
alter table scorecard.secret_prize_config  enable row level security;
alter table scorecard.secret_prize_state   enable row level security;
alter table scorecard.prize_pool           enable row level security;
alter table scorecard.prize_wins           enable row level security;
alter table scorecard.role_permissions     enable row level security;

-- ---------------------------------------------------------------------
-- PUBLIC GUEST APP (anon) — minimum possible surface
-- ---------------------------------------------------------------------

-- games: anon may INSERT a finished/abandoned game for a VISIBLE location only,
-- and may NOT self-declare a prize win (won_prize must be false; the edge
-- function is the only thing that ever sets it true).
create policy anon_insert_games on scorecard.games
  for insert to anon
  with check (
    won_prize = false
    and exists (
      select 1 from scorecard.location_settings ls
      where ls.location_id = scorecard.games.location_id
        and ls.scorecard_status in ('active','coming_soon')
    )
  );

-- newsletter: anon may INSERT only with consent=true. No SELECT.
create policy anon_insert_newsletter on scorecard.newsletter_signups
  for insert to anon with check (consent = true);
-- (Recommend double opt-in at the app layer to prevent third-party email entry.)

-- feedback: anon may INSERT a rating for a visible location. No SELECT.
create policy anon_insert_feedback on scorecard.feedback
  for insert to anon
  with check (
    stars between 1 and 5
    and exists (
      select 1 from scorecard.location_settings ls
      where ls.location_id = scorecard.feedback.location_id
        and ls.scorecard_status in ('active','coming_soon')
    )
  );

-- Location + promo reads for guests happen through the VIEWS
-- (scorecard.public_locations / public_promotions), which are owned by a
-- privileged role and run security_invoker=false, so anon reads the view
-- without table-level grants. Grant SELECT on the views to anon:
grant usage on schema scorecard to anon;
grant select on scorecard.public_locations  to anon;
grant select on scorecard.public_promotions to anon;
-- IMPORTANT: do NOT grant anon select on any base table. Anon sees only the views.

-- ---- ANON table privileges (needed alongside the INSERT policies above) ----
-- RLS and GRANTs are independent layers in Postgres: both must pass.
grant insert on scorecard.games              to anon;
grant insert on scorecard.newsletter_signups to anon;
grant insert on scorecard.feedback           to anon;
-- anon gets NO select/update/delete on base tables, and no rights on the
-- sensitive tables at all (reinforced by the revokes below).

-- ---- AUTHENTICATED (staff) privileges ----
-- Custom schemas do NOT inherit Supabase's default public-schema auto-grants,
-- so we grant explicitly. RLS policies still gate every row; these grants only
-- open the door for the policies to apply.
grant usage on schema scorecard to authenticated;
grant select, insert, update, delete on all tables in schema scorecard to authenticated;
grant select on scorecard.public_locations  to authenticated;
grant select on scorecard.public_promotions to authenticated;
-- Future tables in this schema should inherit the same (optional convenience):
alter default privileges in schema scorecard
  grant select, insert, update, delete on tables to authenticated;
grant execute on function scorecard.has_capability(text) to authenticated, anon;

-- Explicitly ensure anon has NO table privileges on sensitive tables.
revoke all on scorecard.secret_prize_config from anon;
revoke all on scorecard.secret_prize_state  from anon;
revoke all on scorecard.prize_pool          from anon;
revoke all on scorecard.prize_wins          from anon;
revoke all on scorecard.location_settings   from anon;
revoke all on scorecard.role_permissions    from anon;
-- (games/newsletter/feedback: anon keeps INSERT via the grants+policies below, no SELECT)

-- ---------------------------------------------------------------------
-- STAFF (authenticated) — gated by helpers + capability matrix
-- ---------------------------------------------------------------------

-- location_settings: read any (authenticated); write requires capability
create policy staff_read_location_settings on scorecard.location_settings
  for select to authenticated using (true);
create policy staff_write_location_settings on scorecard.location_settings
  for all to authenticated
  using (scorecard.has_capability('configure_location')
         and gz360_auth.gz_can_manage_location(location_id))
  with check (scorecard.has_capability('configure_location')
         and gz360_auth.gz_can_manage_location(location_id));

-- games: staff may read games at locations they can access (for stats)
create policy staff_read_games on scorecard.games
  for select to authenticated
  using (gz360_auth.gz_can_access_location(location_id));

-- feedback: staff read at accessible locations
create policy staff_read_feedback on scorecard.feedback
  for select to authenticated
  using (gz360_auth.gz_can_access_location(location_id));

-- newsletter: staff read requires stats/admin capability (it's PII)
create policy staff_read_newsletter on scorecard.newsletter_signups
  for select to authenticated
  using (scorecard.has_capability('view_stats') or gz360_auth.gz_is_admin());

-- promotions: read any; write needs manage_promos + location scope
create policy staff_read_promos on scorecard.promotions
  for select to authenticated using (true);
create policy staff_write_promos on scorecard.promotions
  for all to authenticated
  using (scorecard.has_capability('manage_promos')
         and (scope='global' and gz360_auth.gz_is_admin()
              or scope='location' and gz360_auth.gz_can_manage_location(location_id)))
  with check (scorecard.has_capability('manage_promos')
         and (scope='global' and gz360_auth.gz_is_admin()
              or scope='location' and gz360_auth.gz_can_manage_location(location_id)));

-- secret_prize_config + prize_pool: configure_secret_prize + scope
create policy staff_read_spc on scorecard.secret_prize_config
  for select to authenticated using (gz360_auth.gz_can_access_location(location_id));
create policy staff_write_spc on scorecard.secret_prize_config
  for all to authenticated
  using (scorecard.has_capability('configure_secret_prize')
         and gz360_auth.gz_can_manage_location(location_id))
  with check (scorecard.has_capability('configure_secret_prize')
         and gz360_auth.gz_can_manage_location(location_id));

create policy staff_read_pool on scorecard.prize_pool
  for select to authenticated
  using (location_id is null or gz360_auth.gz_can_access_location(location_id));
create policy staff_write_pool on scorecard.prize_pool
  for all to authenticated
  using (scorecard.has_capability('configure_secret_prize')
         and (location_id is null and gz360_auth.gz_is_admin()
              or gz360_auth.gz_can_manage_location(location_id)))
  with check (scorecard.has_capability('configure_secret_prize')
         and (location_id is null and gz360_auth.gz_is_admin()
              or gz360_auth.gz_can_manage_location(location_id)));

-- secret_prize_state: NO staff read/write via RLS. Edge function (service
-- role) owns it. (No policies = deny for anon & authenticated. Service role
-- bypasses RLS.)

-- prize_wins: staff may READ at accessible locations (to look up a code) and
-- UPDATE only to confirm (status -> confirmed) when they have redeem_prize.
create policy staff_read_prizewins on scorecard.prize_wins
  for select to authenticated
  using (gz360_auth.gz_can_access_location(location_id));
create policy staff_confirm_prizewins on scorecard.prize_wins
  for update to authenticated
  using (scorecard.has_capability('redeem_prize')
         and gz360_auth.gz_can_access_location(location_id))
  with check (scorecard.has_capability('redeem_prize')
         and gz360_auth.gz_can_access_location(location_id));
-- (INSERT of prize_wins is done by the edge function only — no anon/staff insert policy.)

-- role_permissions: admin reads/writes; others read (so the app can check)
create policy staff_read_perms on scorecard.role_permissions
  for select to authenticated using (true);
create policy admin_write_perms on scorecard.role_permissions
  for all to authenticated
  using (gz360_auth.gz_is_admin()) with check (gz360_auth.gz_is_admin());

commit;

-- =====================================================================
-- EDGE FUNCTION NOTES (build separately, runs with SERVICE ROLE key)
-- ---------------------------------------------------------------------
-- 1. submit_finish(game payload):
--    - inserts the scorecard.games row (could also be a direct anon insert)
--    - evaluates secret prize SERVER-SIDE against secret_prize_state
--    - applies eligibility gate: status='completed', duration >=
--      min_duration_seconds, device cooldown (if set)
--    - applies win_rate + daily_cap (reset awarded_today when award_date<today)
--    - on win: picks a weighted prize from prize_pool, inserts prize_wins
--      (code + qr), sets games.won_prize=true, rotates secret_prize_state,
--      increments awarded_today; returns {win, prize_label, code} or {no_win}
--    - returns ONLY the result to the phone; never the secret.
--
-- 2. The service role bypasses RLS, so secret_prize_state stays unreadable
--    by anon/authenticated while the function can still touch it.
--
-- GO-LIVE RLS TEST (run with ONLY the anon key — every one MUST fail):
--    (1) select from scorecard.games            -> fail
--    (2) select from scorecard.newsletter_signups-> fail
--    (3) select from scorecard.secret_prize_state-> fail
--    (4) select from public.profiles             -> fail
--    (5) select from scorecard.feedback          -> fail
--    (6) update/delete any scorecard row          -> fail
--    Allowed for anon: select from scorecard.public_locations / public_promotions;
--    insert into games / newsletter_signups(consent=true) / feedback.
-- =====================================================================
