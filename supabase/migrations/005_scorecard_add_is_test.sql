begin;

-- Add a test flag so test games can be marked and excluded from real stats.
alter table scorecard.games
  add column if not exists is_test boolean not null default false;

-- The existing anon insert policy already allows inserts for visible locations
-- and forbids won_prize=true; is_test defaults to false and anon may set it true
-- for test rows. No policy change needed (the WITH CHECK doesn't restrict is_test),
-- but we make the intent explicit for future readers:
comment on column scorecard.games.is_test is
  'true = test/QA row, exclude from all real statistics (where is_test = false)';

commit;