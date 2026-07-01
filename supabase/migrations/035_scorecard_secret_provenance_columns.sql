-- ═══════════════════════════════════════════════════════════════════════
--   035_scorecard_secret_provenance_columns.sql
--   Adds provenance to secret_score_current so we can show HOW the current
--   secret was drawn: automatically (after a win / seed) vs manually
--   refreshed (and by whom).
--
--   source   : 'auto' | 'seed' | 'admin_refresh' | 'desk_refresh' | null
--   drawn_by : profile id of the staff member for manual refreshes; null for
--              automatic draws. FK to public.profiles(id), matching the
--              redeemed_by / created_by convention elsewhere.
--
--   Both nullable, no default: existing rows stay null/null (unknown
--   provenance, shown as "automatic"). No backfill. Write paths are updated
--   in migration 036.
-- ═══════════════════════════════════════════════════════════════════════

alter table scorecard.secret_score_current
  add column if not exists source   text,
  add column if not exists drawn_by uuid references public.profiles(id);
