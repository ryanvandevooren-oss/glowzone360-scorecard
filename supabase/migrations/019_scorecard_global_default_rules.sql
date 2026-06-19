-- Migration 019: company-wide default rules + per-location inherit.
-- A single global_settings row holds the company default `rules`. Locations with
-- NULL rules INHERIT it; non-null rules OVERRIDE. public_locations resolves
-- COALESCE(location.rules, global.rules) in the existing `rules` column, so the
-- guest receives already-resolved rules with NO guest logic change. Apply in the
-- Supabase SQL Editor as the privileged role.

-- 1. Singleton global-settings table (one row, enforced by a fixed boolean PK).
create table if not exists scorecard.global_settings (
  id         boolean primary key default true,
  rules      jsonb,
  updated_at timestamptz not null default now(),
  constraint global_settings_singleton check (id = true)
);

insert into scorecard.global_settings (id, rules)
values (true, null)
on conflict (id) do nothing;

-- 2. RLS — anon gets NO direct access (guests read resolved rules via the view).
--    Reads: any authenticated staff (so managers can see the default they inherit).
--    Writes: admin + owner only (company-wide setting; NOT per-location managers).
alter table scorecard.global_settings enable row level security;
revoke all on scorecard.global_settings from anon, public;
grant select, insert, update on scorecard.global_settings to authenticated;

create policy staff_read_global_settings
  on scorecard.global_settings
  for select to authenticated
  using (true);

create policy admin_owner_write_global_settings
  on scorecard.global_settings
  for all to authenticated
  using ( gz360_auth.gz_is_admin() or gz360_auth.gz_current_role() = 'owner' )
  with check ( gz360_auth.gz_is_admin() or gz360_auth.gz_current_role() = 'owner' );

-- 3. Recreate public_locations: IDENTICAL to the live definition, except the
--    `rules` column now resolves location-or-global. Same columns, same order.
--    security_invoker re-stated explicitly (016 dropped it; default was false).
create or replace view scorecard.public_locations
  with (security_invoker = false) as
  select
    l.id                                            as location_id,
    l.name,
    ls.pars,
    ls.hole_count,
    ls.rules_text,
    ls.scorecard_status,
    ls.google_review_url,
    l.sort_order,
    coalesce(
      ls.rules,
      (select g.rules from scorecard.global_settings g where g.id)
    )                                               as rules
  from locations l
  join scorecard.location_settings ls on ls.location_id = l.id
  where ls.scorecard_status = any (array['active'::text, 'coming_soon'::text])
  order by l.sort_order, l.name;
