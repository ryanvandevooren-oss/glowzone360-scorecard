-- =====================================================================
-- 008_scorecard_promotions_multi_location.sql
--
-- Promotions feature, Option B: ONE promotion row shared across many
-- locations, with a per-location on/off toggle. The shared date range
-- (starts_at / ends_at) and the master switch (is_active) stay on the
-- promotion; only the per-location enable/disable lives in a join table.
--
-- ---------------------------------------------------------------------
-- HOW THIS RECONCILES WITH THE EXISTING scope / location_id MODEL
-- ---------------------------------------------------------------------
-- Today scorecard.promotions has:
--     scope        text  check (scope in ('location','global'))
--     location_id  uuid  (one location, for scope='location')
--     promo_scope_loc_chk:  global => location_id null
--                           location => location_id not null
--
-- That model assumes ONE location_id per promo, which directly conflicts
-- with "one promo, many locations." Rather than overload scope='location'
-- (which would force location_id null and break both the CHECK and the
-- meaning of every existing single-location row), we introduce a THIRD,
-- clearly-named scope value:
--
--     scope = 'global'    -> shown everywhere, no toggle, location_id NULL   (unchanged)
--     scope = 'location'  -> legacy single-location promo, location_id set   (unchanged)
--     scope = 'multi'     -> shared promo, location_id NULL, locations live
--                            in scorecard.promotion_locations (the new toggle)
--
-- Why this is the clean choice:
--   * Existing 'global' and 'location' rows are untouched and still valid.
--   * 'multi' is self-describing; no nullable-location ambiguity on the
--     legacy single-location path.
--   * The CHECK constraints are widened (not weakened) — every old row
--     still satisfies them.
--
-- Conflict with promo_scope_loc_chk (the tricky part) is resolved by
-- DROPPING and RE-ADDING it with a third branch for 'multi'
-- (location_id IS NULL, because locations now live in the join table).
-- The inline `scope in (...)` enum check is likewise widened to include
-- 'multi' (dropped by introspection so we don't depend on its auto-name).
--
-- NOTE: this migration also updates staff_write_promos, because the
-- existing policy only permits scope IN ('global','location') writes and
-- would otherwise BLOCK creating a 'multi' promo. See section 5.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. promo_code column on the promotion (nullable; e.g. "GLOW20")
-- ---------------------------------------------------------------------
alter table scorecard.promotions
  add column if not exists promo_code text;

-- ---------------------------------------------------------------------
-- 2. Widen the scope model to add 'multi', reconciling the constraints
-- ---------------------------------------------------------------------
-- Drop the explicitly-named scope/location reconciliation check (certain
-- name), and the inline scope-enum check (auto-named — found by
-- introspection so we don't depend on the generated name). The enum
-- check mentions 'scope' but NOT 'location_id', which distinguishes it
-- from promo_scope_loc_chk.
alter table scorecard.promotions
  drop constraint if exists promo_scope_loc_chk;

do $$
declare cname text;
begin
  select con.conname into cname
  from pg_constraint con
  join pg_class      rel on rel.oid = con.conrelid
  join pg_namespace  nsp on nsp.oid = rel.relnamespace
  where nsp.nspname = 'scorecard'
    and rel.relname = 'promotions'
    and con.contype = 'c'
    and pg_get_constraintdef(con.oid) ilike '%scope%'
    and pg_get_constraintdef(con.oid) not ilike '%location_id%'
  limit 1;
  if cname is not null then
    execute format('alter table scorecard.promotions drop constraint %I', cname);
  end if;
end $$;

-- Re-add both checks, now allowing the 'multi' scope. Every existing
-- ('global' / 'location') row still satisfies these.
alter table scorecard.promotions
  add constraint promo_scope_chk
  check (scope in ('location','global','multi'));

alter table scorecard.promotions
  add constraint promo_scope_loc_chk check (
    (scope = 'global'   and location_id is null) or
    (scope = 'location' and location_id is not null) or
    (scope = 'multi'    and location_id is null));

-- ---------------------------------------------------------------------
-- 3. Per-location on/off toggle join table
--    Date range stays shared on the promotion — no per-location dates.
-- ---------------------------------------------------------------------
create table if not exists scorecard.promotion_locations (
  promotion_id uuid not null
                 references scorecard.promotions(id) on delete cascade,
  location_id  uuid not null
                 references public.locations(id) on delete cascade,
  is_active    boolean     not null default false,   -- the per-location switch
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (promotion_id, location_id)
);

-- Lookup by location (guest view + admin "which promos at location X").
create index if not exists promotion_locations_location_idx
  on scorecard.promotion_locations(location_id);

-- ---------------------------------------------------------------------
-- 4. Rewrite the public guest view: location-resolved promotions
-- ---------------------------------------------------------------------
-- CREATE OR REPLACE (not DROP) so the existing grants to anon /
-- authenticated are preserved. The replacement keeps the original column
-- list in the same order and only APPENDS promo_code at the end, which is
-- the only shape change CREATE OR REPLACE VIEW permits.
--
-- A promo surfaces for a location only when the master switch is on and it
-- is within the shared date range, AND one of:
--   * scope='global'   -> one row, location_id NULL (shown everywhere; unchanged contract)
--   * scope='location' -> legacy single location, if that location is visible
--   * scope='multi'    -> per promotion_locations row with is_active=true,
--                         for each VISIBLE location (one output row per location)
-- "Visible" = location_settings.scorecard_status in ('active','coming_soon').
create or replace view scorecard.public_promotions
with (security_invoker = false) as

  -- Global promos: single row, location_id NULL (matches existing behaviour).
  select p.id, p.title, p.body, p.image_url, p.link_url, p.type,
         p.scope, p.location_id, p.promo_code
  from scorecard.promotions p
  where p.is_active
    and (p.starts_at is null or p.starts_at <= now())
    and (p.ends_at   is null or p.ends_at   >= now())
    and p.scope = 'global'

  union all

  -- Legacy single-location promos: surface for their location if visible.
  select p.id, p.title, p.body, p.image_url, p.link_url, p.type,
         p.scope, p.location_id, p.promo_code
  from scorecard.promotions p
  join scorecard.location_settings ls on ls.location_id = p.location_id
  where p.is_active
    and (p.starts_at is null or p.starts_at <= now())
    and (p.ends_at   is null or p.ends_at   >= now())
    and p.scope = 'location'
    and ls.scorecard_status in ('active','coming_soon')

  union all

  -- Multi-location promos: one row per toggled-ON, visible location.
  select p.id, p.title, p.body, p.image_url, p.link_url, p.type,
         p.scope, pl.location_id, p.promo_code
  from scorecard.promotions p
  join scorecard.promotion_locations pl
       on pl.promotion_id = p.id and pl.is_active = true
  join scorecard.location_settings ls on ls.location_id = pl.location_id
  where p.is_active
    and (p.starts_at is null or p.starts_at <= now())
    and (p.ends_at   is null or p.ends_at   >= now())
    and p.scope = 'multi'
    and ls.scorecard_status in ('active','coming_soon');

-- ---------------------------------------------------------------------
-- 5. RLS + grants on promotion_locations (mirror the promotions policies)
-- ---------------------------------------------------------------------
-- promotions today: READ to any authenticated (using true); WRITE needs
-- manage_promos + scope-appropriate location authority. We mirror that:
-- per-location toggle rows always carry a location_id, so writes use the
-- same gz_can_manage_location() gate as the 'location' branch. Anon gets
-- NOTHING here — guests only ever read the view above.

alter table scorecard.promotion_locations enable row level security;

-- Custom-schema tables don't inherit Supabase's default grants; grant
-- explicitly (the schema's default-privileges rule covers this too, but
-- being explicit keeps the migration self-contained).
grant select, insert, update, delete on scorecard.promotion_locations to authenticated;
revoke all on scorecard.promotion_locations from anon;

-- Read: any authenticated staff (same as staff_read_promos).
create policy staff_read_promo_locations on scorecard.promotion_locations
  for select to authenticated
  using (true);

-- Write: manage_promos capability + authority over THAT location.
create policy staff_write_promo_locations on scorecard.promotion_locations
  for all to authenticated
  using (scorecard.has_capability('manage_promos')
         and gz360_auth.gz_can_manage_location(location_id))
  with check (scorecard.has_capability('manage_promos')
         and gz360_auth.gz_can_manage_location(location_id));

-- ---------------------------------------------------------------------
-- 5b. Allow writing the new 'multi' parent promo row
-- ---------------------------------------------------------------------
-- The existing staff_write_promos only matches scope IN ('global','location')
-- and would reject a scope='multi' INSERT/UPDATE (location_id is NULL, so the
-- 'location' branch fails and the 'global' branch's scope test fails). Replace
-- it to add a 'multi' branch. A multi promo is a cross-location object, so we
-- gate its PARENT row to admin OR owner — NOT every manage_promos holder
-- (location_manager also has manage_promos but should not create org-wide
-- promos). There is no gz_is_owner() helper, so we combine the existing
-- gz_is_admin() helper with the established public.profiles.role lookup used
-- inside scorecard.has_capability(). Per-location enablement stays gated
-- row-by-row in promotion_locations above. ('global' and 'location' branches
-- are unchanged.)
drop policy if exists staff_write_promos on scorecard.promotions;
create policy staff_write_promos on scorecard.promotions
  for all to authenticated
  using (scorecard.has_capability('manage_promos')
         and (
           (scope = 'global'   and gz360_auth.gz_is_admin())
           or (scope = 'location' and gz360_auth.gz_can_manage_location(location_id))
           or (scope = 'multi'    and (gz360_auth.gz_is_admin()
                                       or (select role from public.profiles where id = auth.uid()) = 'owner'))
         ))
  with check (scorecard.has_capability('manage_promos')
         and (
           (scope = 'global'   and gz360_auth.gz_is_admin())
           or (scope = 'location' and gz360_auth.gz_can_manage_location(location_id))
           or (scope = 'multi'    and (gz360_auth.gz_is_admin()
                                       or (select role from public.profiles where id = auth.uid()) = 'owner'))
         ));

commit;

-- =====================================================================
-- Rollback notes (manual, if ever needed):
--   drop view scorecard.public_promotions;  -- then recreate the 007 version
--   drop table scorecard.promotion_locations;
--   alter table scorecard.promotions drop constraint promo_scope_chk;
--   alter table scorecard.promotions drop constraint promo_scope_loc_chk;
--   -- re-add original 2-value checks; drop column promo_code;
--   -- restore the original staff_write_promos policy.
-- =====================================================================
