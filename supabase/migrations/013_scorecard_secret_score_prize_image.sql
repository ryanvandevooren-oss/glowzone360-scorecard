-- =====================================================================
-- 013_scorecard_secret_score_prize_image.sql
--
-- Adds a nullable image_url to scorecard.secret_score_prizes so the guest
-- full-screen win reveal can show a photo of the prize. Admins upload it the
-- same way promotions images work (Supabase Storage → public URL stored here).
--
-- No other schema changes.
--
-- RLS: NO CHANGES NEEDED. image_url is a plain column on an existing table,
-- already covered by the staff_rw_secret_prizes policy from migration 010
-- (Postgres row policies apply to all columns, including new ones; no
-- column-level RLS is in use). Guests never read secret_score_prizes directly —
-- the prize image reaches them through the engine RPC's win response
-- (prize_image, added in a later migration), NOT via any public view.
-- =====================================================================

begin;

alter table scorecard.secret_score_prizes
  add column if not exists image_url text;

commit;

-- Rollback (manual, if ever needed):
--   alter table scorecard.secret_score_prizes drop column image_url;
