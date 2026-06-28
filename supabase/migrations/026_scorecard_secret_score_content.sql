-- Migration 026: Secret Score "experience" data model.
-- Adds editable splash/win/lose content (global) + exposes a SAFE pre-game
-- signal to the guest. Part of the Secret Score splash + glowing reveal build.
--
-- global_settings.secret_score_content jsonb — the editable copy:
--   { splash:{eyebrow,headline,body,prize_text,prize_image_url},
--     win:{headline,detail_template}, lose:{headline,body,comeback_text} }
--   (nullable; authored in the admin Company Defaults editor.)
--
-- public_locations gains two columns so the guest knows PRE-GAME whether to
-- show the splash/lose and what copy to render (the view is security_invoker
-- =false, so it reads the anon-revoked config tables on the guest's behalf,
-- leaking only a boolean + the copy — never the secret hole/score):
--   secret_score_active boolean = master_enabled AND this-location enabled
--   secret_score_content jsonb  = passthrough of the global copy
--
-- View rebuilt from the LIVE pg_get_viewdef (not the repo copy — drift trap),
-- new columns appended last, security_invoker=false preserved. The join to
-- secret_score_config is a LEFT JOIN so locations without a config row still
-- appear (secret_score_active=false) rather than being dropped.
-- Apply in the Supabase SQL Editor as the privileged role.

alter table scorecard.global_settings
  add column if not exists secret_score_content jsonb;

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
    ls.max_strokes_per_hole,
    (coalesce((select g.secret_score_enabled from scorecard.global_settings g where g.id), true)
       and coalesce(sc.enabled, false)) as secret_score_active,
    (select g.secret_score_content
           from scorecard.global_settings g
          where g.id) as secret_score_content
   from locations l
     join scorecard.location_settings ls on ls.location_id = l.id
     left join scorecard.secret_score_config sc on sc.location_id = l.id
  where ls.scorecard_status = any (array['active'::text, 'coming_soon'::text])
  order by l.sort_order, l.name;
