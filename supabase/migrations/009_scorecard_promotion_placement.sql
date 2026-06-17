-- =====================================================================
-- 009_scorecard_promotion_placement.sql
--
-- Per-promotion PLACEMENT control: where in the guest flow a promo shows.
--   show_on_welcome  -> before play (welcome / location screen)
--   show_on_winner   -> after play  (winner screen)
-- The two are independent (a promo may show in neither, either, or both).
--
-- Defaults are chosen so EXISTING promos behave as before:
--   show_on_winner  default TRUE   -> promos keep showing where they
--                                     traditionally appear (winner screen)
--   show_on_welcome default FALSE  -> nothing suddenly appears pre-play
--
-- This migration only adds two columns and surfaces them in the public
-- view. It does NOT change any of the view's filtering/gating logic, and
-- it needs NO RLS changes (see note at the bottom).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Placement flags on the promotion
-- ---------------------------------------------------------------------
-- NOT NULL + default backfills every existing row with the default
-- (winner=true, welcome=false), preserving current behaviour.
alter table scorecard.promotions
  add column if not exists show_on_welcome boolean not null default false;
alter table scorecard.promotions
  add column if not exists show_on_winner  boolean not null default true;

-- ---------------------------------------------------------------------
-- 2. Surface the flags in the public guest view
-- ---------------------------------------------------------------------
-- CREATE OR REPLACE (not DROP) so the existing grants to anon /
-- authenticated are preserved. The replacement keeps the 008 column list
-- in the SAME order and only APPENDS show_on_welcome + show_on_winner at
-- the end — the only shape change CREATE OR REPLACE VIEW permits.
--
-- IMPORTANT: the 3-branch structure (global / location / multi) and ALL
-- gating (is_active master switch + shared date range + location
-- visibility) are reproduced EXACTLY as in migration 008. The only change
-- is the two extra columns in each branch's SELECT list. The guest app
-- decides placement per row using these flags; the view does not filter on
-- them (a promo with both flags false simply has no enabled placement, but
-- still appears in the view — the client is the placement authority).
create or replace view scorecard.public_promotions
with (security_invoker = false) as

  -- Global promos: single row, location_id NULL (shown everywhere).
  select p.id, p.title, p.body, p.image_url, p.link_url, p.type,
         p.scope, p.location_id, p.promo_code,
         p.show_on_welcome, p.show_on_winner
  from scorecard.promotions p
  where p.is_active
    and (p.starts_at is null or p.starts_at <= now())
    and (p.ends_at   is null or p.ends_at   >= now())
    and p.scope = 'global'

  union all

  -- Legacy single-location promos: surface for their location if visible.
  select p.id, p.title, p.body, p.image_url, p.link_url, p.type,
         p.scope, p.location_id, p.promo_code,
         p.show_on_welcome, p.show_on_winner
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
         p.scope, pl.location_id, p.promo_code,
         p.show_on_welcome, p.show_on_winner
  from scorecard.promotions p
  join scorecard.promotion_locations pl
       on pl.promotion_id = p.id and pl.is_active = true
  join scorecard.location_settings ls on ls.location_id = pl.location_id
  where p.is_active
    and (p.starts_at is null or p.starts_at <= now())
    and (p.ends_at   is null or p.ends_at   >= now())
    and p.scope = 'multi'
    and ls.scorecard_status in ('active','coming_soon');

commit;

-- =====================================================================
-- 3. RLS: NO CHANGES NEEDED — confirmed.
--   * show_on_welcome / show_on_winner are plain columns on
--     scorecard.promotions, already covered by the existing
--     staff_read_promos (SELECT) and staff_write_promos (write) policies
--     from the RLS migration. Column-level RLS is not in use; row policies
--     apply to all columns, including new ones.
--   * Guests never touch the base table — they read scorecard.public_
--     promotions, which is security_invoker=false and already granted to
--     anon. CREATE OR REPLACE preserved that grant, so anon automatically
--     sees the two new view columns. No grant/policy statements required.
--
-- Rollback notes (manual, if ever needed):
--   -- recreate the 008 version of the view (without the two columns), then:
--   alter table scorecard.promotions drop column show_on_winner;
--   alter table scorecard.promotions drop column show_on_welcome;
-- =====================================================================
