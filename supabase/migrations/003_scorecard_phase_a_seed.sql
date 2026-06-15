-- =====================================================================
-- GlowZone 360 Scorecard — Phase A seed
-- Run AFTER 001 (schema) and 002 (RLS).
-- Uses the real location UUIDs from public.locations.
--   Brampton     eab04053-a7b2-49f4-962b-59f5c7803ebe  (Hub: active)
--   Mississauga  fd33ba23-d78c-4d10-a221-8d3b1443bdba  (Hub: active)
--   Etobicoke    9e714cb9-756e-4bf3-aeb0-3beaeadfaaaf  (Hub: draft)
-- NOTE: scorecard_status is INDEPENDENT of the Hub's status. Etobicoke is a
-- Hub 'draft' but we show it as 'coming_soon' for buzz. Change to 'hidden'
-- if you don't want the teaser yet.
-- =====================================================================

begin;

-- ---- location_settings ----
insert into scorecard.location_settings
  (location_id, scorecard_status, rules_text)
values
  ('eab04053-a7b2-49f4-962b-59f5c7803ebe','active',
   'Up to 5 players per scorecard. Nine strokes max on any hole. Out of bounds? Replace the ball where it left the course and add one stroke. Move the ball one putter-head from an obstruction, no closer to the hole. Play safe: gentle swings only, keep the putter head below your ankles, no running, jumping, or climbing on props.'),
  ('fd33ba23-d78c-4d10-a221-8d3b1443bdba','active',
   'Up to 5 players per scorecard. Nine strokes max on any hole. Out of bounds? Replace the ball where it left the course and add one stroke. Move the ball one putter-head from an obstruction, no closer to the hole. Play safe: gentle swings only, keep the putter head below your ankles, no running, jumping, or climbing on props.'),
  ('9e714cb9-756e-4bf3-aeb0-3beaeadfaaaf','coming_soon','')
on conflict (location_id) do nothing;
-- pars default to [3×17,2] and fun_features default to all-on (see schema).

-- ---- secret prize config (off by default; admin turns on per location) ----
insert into scorecard.secret_prize_config (location_id, enabled)
values
  ('eab04053-a7b2-49f4-962b-59f5c7803ebe', false),
  ('fd33ba23-d78c-4d10-a221-8d3b1443bdba', false)
on conflict (location_id) do nothing;

-- ---- secret prize state (seed a starting secret so rotation has a base) ----
insert into scorecard.secret_prize_state (location_id, active_hole, active_score)
values
  ('eab04053-a7b2-49f4-962b-59f5c7803ebe', 7, 1),
  ('fd33ba23-d78c-4d10-a221-8d3b1443bdba', 7, 1)
on conflict (location_id) do nothing;

-- ---- starter prize pool (edit values/labels/weights in admin later) ----
insert into scorecard.prize_pool (location_id, label, value, weight) values
  ('eab04053-a7b2-49f4-962b-59f5c7803ebe','$5 Game Card', 5, 6),
  ('eab04053-a7b2-49f4-962b-59f5c7803ebe','$10 Game Card',10, 3),
  ('eab04053-a7b2-49f4-962b-59f5c7803ebe','Free Game',   8, 2),
  ('eab04053-a7b2-49f4-962b-59f5c7803ebe','Slushy',      4, 5),
  ('fd33ba23-d78c-4d10-a221-8d3b1443bdba','$5 Game Card', 5, 6),
  ('fd33ba23-d78c-4d10-a221-8d3b1443bdba','$10 Game Card',10, 3),
  ('fd33ba23-d78c-4d10-a221-8d3b1443bdba','Free Game',   8, 2),
  ('fd33ba23-d78c-4d10-a221-8d3b1443bdba','Slushy',      4, 5)
on conflict do nothing;

commit;
