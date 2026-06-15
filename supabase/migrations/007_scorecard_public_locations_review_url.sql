begin;

-- Phase B3: expose google_review_url to the anonymous guest app so the post-game
-- feedback flow can link 4-5 star players to the location's Google review page.
-- The column already exists on scorecard.location_settings but was not surfaced;
-- anon has no SELECT on the base table, so it must come through this view.
-- CREATE OR REPLACE only appends a column at the end (no reorder/removal), and the
-- existing `grant select on scorecard.public_locations to anon` covers it.
create or replace view scorecard.public_locations
with (security_invoker = false) as
  select l.id                 as location_id,
         l.name               as name,
         ls.pars              as pars,
         ls.hole_count        as hole_count,
         ls.rules_text        as rules_text,
         ls.scorecard_status  as scorecard_status,
         ls.google_review_url as google_review_url
  from public.locations l
  join scorecard.location_settings ls on ls.location_id = l.id
  where ls.scorecard_status in ('active','coming_soon');

commit;
