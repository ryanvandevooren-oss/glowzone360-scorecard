-- Migration 025: per-location max strokes per hole (pace-of-play cap).
-- Lets managers cap the guest score keypad (e.g. 1-6) during busy periods.
-- Default 9 = current behavior (keypad already maxes at 9), so existing
-- locations are unchanged. Flat cap, new-entries-only on the guest (it limits
-- the keypad; existing scores are never rewritten). public_locations view
-- exposes it so the guest can read it. View rebuilt from the LIVE pg_get_viewdef
-- (not the repo copy) with the new column appended last; security_invoker=false
-- preserved. Apply in the Supabase SQL Editor as the privileged role.

alter table scorecard.location_settings
  add column if not exists max_strokes_per_hole int not null default 9
  check (max_strokes_per_hole between 1 and 9);

create or replace view scorecard.public_locations with (security_invoker = false) as
  select l.id as location_id,
    l.name,
    ls.pars,
    ls.hole_count,
    ls.rules_text,
    ls.scorecard_status,
    ls.google_review_url,
    l.sort_order,
    coalesce(ls.rules, (select g.rules
           from scorecard.global_settings g
          where g.id)) as rules,
    (select g.score_titles
           from scorecard.global_settings g
          where g.id) as score_titles,
    ls.max_strokes_per_hole
   from locations l
     join scorecard.location_settings ls on ls.location_id = l.id
  where ls.scorecard_status = any (array['active'::text, 'coming_soon'::text])
  order by l.sort_order, l.name;
