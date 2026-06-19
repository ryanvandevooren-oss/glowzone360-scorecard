-- Migration 021: reshape score_titles from a flat array into performance BANDS.
-- score_titles becomes {"over":[...], "around":[...], "under":[...]} — fun
-- fallback titles keyed to how a player scored vs par. The existing flat titles
-- move into "around"; "over"/"under" get starter titles (admin re-curates).
-- IDEMPOTENT: only reshapes when the value is still a flat array, so re-running
-- (or running after the column is already an object) never clobbers curated data.
-- public_locations is UNCHANGED — it passes score_titles through as raw jsonb,
-- shape-agnostic. Apply in the Supabase SQL Editor as the privileged role.

update scorecard.global_settings
   set score_titles = jsonb_build_object(
         'over',  '["The Scenic Route","Future Legend in Training","Putter Still Warming Up","Here for a Good Time, Not a Low Time"]'::jsonb,
         'around', coalesce(score_titles, '[]'::jsonb),   -- existing flat 10 land here
         'under', '["Course Crusher","Putt Prodigy","On Fire Tonight","The Closer"]'::jsonb
       ),
       updated_at = now()
 where id = true
   and jsonb_typeof(score_titles) = 'array';   -- only reshape the flat (legacy) shape

-- If score_titles was NULL (no flat array to move), seed the banded shape fresh.
update scorecard.global_settings
   set score_titles = jsonb_build_object(
         'over',  '["The Scenic Route","Future Legend in Training","Putter Still Warming Up","Here for a Good Time, Not a Low Time"]'::jsonb,
         'around', '[]'::jsonb,
         'under', '["Course Crusher","Putt Prodigy","On Fire Tonight","The Closer"]'::jsonb
       ),
       updated_at = now()
 where id = true
   and score_titles is null;
