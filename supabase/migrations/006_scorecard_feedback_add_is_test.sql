begin;

-- Phase B3: flag test/QA feedback so it can be excluded from real stats.
-- Mirrors 005_scorecard_add_is_test.sql for scorecard.games.
alter table scorecard.feedback
  add column if not exists is_test boolean not null default false;

-- The existing anon_insert_feedback policy only constrains stars (1-5) and a
-- visible location; its WITH CHECK does not restrict is_test, so anon may set it
-- true for test rows. No policy change needed (intent made explicit here).
comment on column scorecard.feedback.is_test is
  'true = test/QA row, exclude from all real statistics (where is_test = false)';

commit;
