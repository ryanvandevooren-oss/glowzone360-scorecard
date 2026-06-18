-- Migration 016: structured per-location rules (jsonb), keep rules_text as fallback
-- Apply in Supabase SQL Editor as the privileged role.

-- 1. New column on the base table the admin writes to.
alter table scorecard.location_settings
  add column if not exists rules jsonb;

-- 2. Recreate the public_locations view to expose `rules` to the guest (anon).
--    New column appended at the END (create-or-replace can't insert mid-list).
create or replace view scorecard.public_locations as
  select
    l.id            as location_id,
    l.name,
    ls.pars,
    ls.hole_count,
    ls.rules_text,
    ls.scorecard_status,
    ls.google_review_url,
    l.sort_order,
    ls.rules
  from locations l
  join scorecard.location_settings ls on ls.location_id = l.id
  where ls.scorecard_status = any (array['active'::text, 'coming_soon'::text])
  order by l.sort_order, l.name;

-- 3. Seed Brampton & Mississauga from their existing rules_text, structured.
update scorecard.location_settings
set rules = '{
  "sections": [
    {
      "heading": "Rules of play",
      "items": [
        "Up to 5 players per scorecard.",
        "Nine strokes max on any hole.",
        "Out of bounds? Replace the ball where it left the course and add one stroke.",
        "Move the ball one putter-head from an obstruction, no closer to the hole.",
        "Give other groups room to play."
      ]
    },
    {
      "heading": "Play safe",
      "items": [
        "Gentle swings only.",
        "Keep the putter head below your ankles.",
        "No running, jumping, or climbing on props."
      ]
    }
  ],
  "warning": "Dangerous play means leaving the course."
}'::jsonb
where location_id in (
  'eab04053-a7b2-49f4-962b-59f5c7803ebe',  -- Brampton
  'fd33ba23-d78c-4d10-a221-8d3b1443bdba'   -- Mississauga
);

-- 4. Verify
select location_id, (rules is not null) as has_rules, rules_text is not null as has_legacy
from scorecard.location_settings;
