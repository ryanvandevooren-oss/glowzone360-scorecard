-- Migration 020: company-wide Score Titles fun pool.
-- Adds score_titles (jsonb array of fun fallback titles) to the global_settings
-- singleton, seeded with starters. public_locations surfaces it as a global
-- scalar subquery (same pattern as 019's rules resolution) so anonymous guests
-- read it via the view they already fetch. Built from the LIVE (019) view def.
-- Apply in the Supabase SQL Editor as the privileged role.

-- 1. Fun-pool column on the singleton, seeded with the starter titles.
alter table scorecard.global_settings
  add column if not exists score_titles jsonb;

update scorecard.global_settings
   set score_titles = '[
     "Glow Getter","Putt Star","Mini Golf Maverick","Neon Knight",
     "The Glow-and-Slow","Hole Seeker","Captain Comeback","Smooth Operator",
     "The Lucky Putter","Glow-rious"
   ]'::jsonb
 where id = true and score_titles is null;

-- 2. Recreate public_locations: IDENTICAL to the live 019 definition, PLUS a
--    score_titles column from the global singleton (appended last). rules keeps
--    its 019 COALESCE; security_invoker re-stated; column order preserved.
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
    )                                               as rules,
    (select g.score_titles from scorecard.global_settings g where g.id)
                                                    as score_titles
  from locations l
  join scorecard.location_settings ls on ls.location_id = l.id
  where ls.scorecard_status = any (array['active'::text, 'coming_soon'::text])
  order by l.sort_order, l.name;
