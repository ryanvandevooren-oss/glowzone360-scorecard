-- =====================================================================
-- 014_scorecard_secret_score_prize_disclaimer.sql
--
-- Adds a nullable per-prize disclaimer (terms) to secret_score_prizes, e.g.
-- "Free game valid Mon–Thurs" vs "One slushy per guest". Shown on the guest
-- win reveal next to the prize image + name.
--
-- image_url already exists (migration 013). The GLOBAL teaser_text and
-- win_reveal_text stay on secret_score_config — NOT moved here.
--
-- No other schema changes. RLS: NO CHANGE — disclaimer is a plain column on an
-- existing table, already covered by staff_rw_secret_prizes (migration 010).
-- Guests never read this table directly; the disclaimer reaches them via the
-- engine RPC's win response (prize_disclaimer, added in migration 015).
-- =====================================================================

begin;

alter table scorecard.secret_score_prizes
  add column if not exists disclaimer text;

commit;

-- Rollback (manual):
--   alter table scorecard.secret_score_prizes drop column disclaimer;
