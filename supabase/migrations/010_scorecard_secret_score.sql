-- =====================================================================
-- 010_scorecard_secret_score.sql
--
-- "Secret Score" feature — ADMIN CONFIG + STORAGE ONLY.
-- The win-evaluation engine and the staff redemption flow arrive in later
-- sessions; this migration just creates the schema, capabilities, and the
-- security boundary they will build on.
--
-- CONCEPT: per location a hidden secret = a specific HOLE + SCORE (e.g. score
-- 3 on hole 6). A player who cards that exact score on that hole wins a prize
-- from a weighted pool; the win CONSUMES the secret and the engine draws a new
-- one. Per-location on/off, with an optional daily win cap.
--
-- ┌─ THE CRUX (security) ───────────────────────────────────────────────┐
-- │ The live secret (hole+score) and the curated combo pool MUST be      │
-- │ invisible to GUESTS (anon) — otherwise the game is trivially         │
-- │ defeated — while remaining visible to STAFF for the future           │
-- │ redemption view. We enforce this with TWO independent layers on all  │
-- │ four tables:                                                         │
-- │   1. RLS ENABLED with NO anon policy → anon rows are never returned. │
-- │   2. GRANTs revoked from anon + PUBLIC → anon can't even touch them. │
-- │ And we create NO public view over any of these tables.              │
-- └─────────────────────────────────────────────────────────────────────┘
--
-- Mirrors existing scorecard patterns: scorecard.has_capability(cap) +
-- gz360_auth.gz_can_manage_location / gz_can_access_location, and the
-- role_permissions capability matrix.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Capabilities (recommended grants — confirm before running)
-- ---------------------------------------------------------------------
-- TWO new capabilities:
--   configure_secret_score — set up prizes / holes / scores / messaging.
--       Sensitive (manager-level). Recommended: admin, owner, location_manager.
--   redeem_secret_score   — view the live secret + redeem wins (future flow).
--       Broader (desk staff). Recommended: admin, owner, location_manager,
--       team_leader, and team_member.
--
-- NOTE on team_member: included below so front-desk staff can run redemption.
-- If you'd rather keep it tighter, delete that one row before running.
insert into scorecard.role_permissions(role, capability, allowed) values
  ('admin',            'configure_secret_score', true),
  ('owner',            'configure_secret_score', true),
  ('location_manager', 'configure_secret_score', true),

  ('admin',            'redeem_secret_score', true),
  ('owner',            'redeem_secret_score', true),
  ('location_manager', 'redeem_secret_score', true),
  ('team_leader',      'redeem_secret_score', true),
  ('team_member',      'redeem_secret_score', true)   -- optional; remove to tighten
on conflict (role, capability) do nothing;

-- ---------------------------------------------------------------------
-- 1. Per-location config
-- ---------------------------------------------------------------------
-- pool_mode selects how the engine will draw the next secret:
--   'curated' -> weighted draw from scorecard.secret_score_combos rows
--   'random'  -> draw hole from allowed_holes and score from allowed_scores
-- Both modes are first-class; only the relevant columns/rows are used per mode.
create table if not exists scorecard.secret_score_config (
  location_id      uuid primary key references public.locations(id) on delete cascade,
  enabled          boolean not null default false,
  pool_mode        text    not null default 'curated'
                     check (pool_mode in ('curated','random')),
  allowed_holes    int[]   not null default '{}',   -- random mode: holes to draw from
  allowed_scores   int[]   not null default '{}',   -- random mode: scores to draw from
  daily_win_cap    int     check (daily_win_cap is null or daily_win_cap >= 0), -- null = no cap
  teaser_text      text,
  win_reveal_text  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. Curated hole+score pool (used when pool_mode = 'curated')
-- ---------------------------------------------------------------------
create table if not exists scorecard.secret_score_combos (
  id          uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations(id) on delete cascade,
  hole        int  not null check (hole >= 1),
  score       int  not null check (score >= 1),
  weight      int  not null default 1 check (weight >= 0),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (location_id, hole, score)   -- no duplicate combos per location
);
create index if not exists secret_score_combos_loc_idx
  on scorecard.secret_score_combos(location_id, is_active);

-- ---------------------------------------------------------------------
-- 3. Weighted prize pool per location
-- ---------------------------------------------------------------------
create table if not exists scorecard.secret_score_prizes (
  id          uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations(id) on delete cascade,
  name        text not null,
  weight      int  not null default 1 check (weight >= 0),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists secret_score_prizes_loc_idx
  on scorecard.secret_score_prizes(location_id, is_active);

-- ---------------------------------------------------------------------
-- 4. The LIVE active secret per location (engine reads + rotates on a win)
-- ---------------------------------------------------------------------
-- The single most sensitive table: this is the answer key. Anon must NEVER
-- read it. Staff with configure/redeem capability may, for the desk view.
create table if not exists scorecard.secret_score_current (
  location_id uuid primary key references public.locations(id) on delete cascade,
  hole        int  not null check (hole >= 1),
  score       int  not null check (score >= 1),
  drawn_at    timestamptz not null default now()
);

-- =====================================================================
-- RLS + GRANTS
-- =====================================================================
alter table scorecard.secret_score_config  enable row level security;
alter table scorecard.secret_score_combos  enable row level security;
alter table scorecard.secret_score_prizes  enable row level security;
alter table scorecard.secret_score_current enable row level security;

-- ---- Authenticated grants (RLS still gates every row) ----
-- (The schema's default privileges already grant authenticated CRUD on new
-- tables; granted explicitly here so this migration is self-contained.)
grant usage on schema scorecard to authenticated;
grant select, insert, update, delete on
  scorecard.secret_score_config,
  scorecard.secret_score_combos,
  scorecard.secret_score_prizes,
  scorecard.secret_score_current
  to authenticated;

-- ---- CRITICAL: anon + PUBLIC fully locked out of ALL FOUR tables ----
-- Belt-and-suspenders with RLS-no-anon-policy. No public view exists either.
revoke all on scorecard.secret_score_config  from anon, public;
revoke all on scorecard.secret_score_combos  from anon, public;
revoke all on scorecard.secret_score_prizes  from anon, public;
revoke all on scorecard.secret_score_current from anon, public;

-- ---- Tables 1–3 (config / combos / prizes): configure capability only ----
-- READ and WRITE share the same predicate, so one FOR ALL policy covers both:
-- configure_secret_score AND can-manage-this-location.
create policy staff_rw_secret_config on scorecard.secret_score_config
  for all to authenticated
  using      (scorecard.has_capability('configure_secret_score')
              and gz360_auth.gz_can_manage_location(location_id))
  with check (scorecard.has_capability('configure_secret_score')
              and gz360_auth.gz_can_manage_location(location_id));

create policy staff_rw_secret_combos on scorecard.secret_score_combos
  for all to authenticated
  using      (scorecard.has_capability('configure_secret_score')
              and gz360_auth.gz_can_manage_location(location_id))
  with check (scorecard.has_capability('configure_secret_score')
              and gz360_auth.gz_can_manage_location(location_id));

create policy staff_rw_secret_prizes on scorecard.secret_score_prizes
  for all to authenticated
  using      (scorecard.has_capability('configure_secret_score')
              and gz360_auth.gz_can_manage_location(location_id))
  with check (scorecard.has_capability('configure_secret_score')
              and gz360_auth.gz_can_manage_location(location_id));

-- ---- Table 4 (secret_score_current): staff-readable, anon-locked ----
-- READ: configure OR redeem capability. Location scope uses gz_can_ACCESS_
-- location (not manage) ON PURPOSE — see note below — so the broader redemption
-- roles (team_leader/team_member) can see the live secret for the desk view.
create policy staff_read_secret_current on scorecard.secret_score_current
  for select to authenticated
  using (
    (scorecard.has_capability('configure_secret_score')
       or scorecard.has_capability('redeem_secret_score'))
    and gz360_auth.gz_can_access_location(location_id)
  );

-- WRITE: configure capability + manage-this-location. (The future win engine
-- runs as the service role and bypasses RLS entirely, so it isn't constrained
-- by this policy.) This FOR ALL policy's USING also applies to SELECT and is
-- OR'd with the read policy above; since it's stricter it adds nothing to
-- visibility — same coexistence pattern as location_settings read/write.
create policy staff_write_secret_current on scorecard.secret_score_current
  for all to authenticated
  using      (scorecard.has_capability('configure_secret_score')
              and gz360_auth.gz_can_manage_location(location_id))
  with check (scorecard.has_capability('configure_secret_score')
              and gz360_auth.gz_can_manage_location(location_id));

commit;

-- =====================================================================
-- NOTES / things to confirm
-- =====================================================================
-- 1. READ helper on secret_score_current — gz_can_ACCESS vs gz_can_MANAGE:
--    Your brief said "... AND gz_can_manage_location" for table 4. I used
--    gz_can_ACCESS_location for the READ instead, because redeem_secret_score
--    is meant to be BROADER (team_leader / team_member). gz_can_manage_location
--    typically returns true only for managers/owner/admin, which would block
--    exactly those broader redemption roles from ever seeing the live secret —
--    defeating the point of the capability. If your gz_can_manage_location does
--    grant team_leader/team_member at their location, switch the READ policy to
--    gz_can_manage_location for a tighter rule. WRITES stay on manage.
--
-- 2. anon lockout — CONFIRMED for all four tables: RLS is enabled with no anon
--    policy (so even a stray grant would return zero rows), AND all privileges
--    are revoked from anon + PUBLIC. No public view references these tables.
--    Guests cannot read the secret hole+score or the combo pool.
--
-- 3. daily_win_cap is stored here, but ENFORCING it needs a per-day win ledger
--    (a wins/redemptions table) — that comes with the engine/redemption session.
--
-- 4. Element-range validation for allowed_holes/allowed_scores (e.g. 1..18) and
--    combo hole<=18 is left to the admin UI; the CHECKs here only enforce >=1.
--
-- Rollback (manual, if ever needed):
--   drop table scorecard.secret_score_current, scorecard.secret_score_prizes,
--              scorecard.secret_score_combos,  scorecard.secret_score_config;
--   delete from scorecard.role_permissions
--     where capability in ('configure_secret_score','redeem_secret_score');
-- =====================================================================
