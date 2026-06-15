-- =====================================================================
-- GlowZone 360 Scorecard — Phase A schema
-- Target: the EXISTING Ops Hub Supabase project (qfwqdqlzzolyahjcqmka)
-- Convention (mirrors Ops Hub): SELECT open to authenticated where useful,
--   writes locked via gz360_auth helpers + service-role edge functions,
--   anon (public guest app) access is deny-by-default with ONE narrow view.
--
-- IMPORTANT: This references the existing public.locations(id uuid) and
-- public.profiles(role, location_id) and the gz360_auth.* helper functions.
-- Run in a migration; review every RLS policy before go-live.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Dedicated schema keeps scorecard tables separate from Ops Hub tables
-- ---------------------------------------------------------------------
create schema if not exists scorecard;

-- =====================================================================
-- 1. scorecard.location_settings
--    Extension of public.locations. One row per location that
--    participates in the scorecard. Holds golf-specific config.
-- =====================================================================
create table if not exists scorecard.location_settings (
  location_id        uuid primary key
                       references public.locations(id) on delete cascade,
  scorecard_status   text not null default 'hidden'
                       check (scorecard_status in ('hidden','coming_soon','active')),
  pars               int[] not null default '{3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,2}',
  hole_count         int  not null default 18,
  rules_text         text not null default '',
  google_review_url  text,
  secret_prize_enabled boolean not null default false,
  fun_features       jsonb not null default
                       '{"score_titles":true,"birthday_mode":true,"daily_best":true,"cross_location_nudge":true,"rematch":true,"feedback_prompt":true}'::jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- guard: pars length must match hole_count
alter table scorecard.location_settings
  add constraint pars_length_chk
  check (array_length(pars,1) = hole_count);

-- =====================================================================
-- 2. scorecard.games  (anonymous; NO player names)
-- =====================================================================
create table if not exists scorecard.games (
  id               uuid primary key default gen_random_uuid(),
  location_id      uuid not null references public.locations(id) on delete restrict,
  player_count     int  not null check (player_count between 1 and 5),
  scores           jsonb not null,         -- [[h1..h18],[...]]  per player, nulls ok
  totals           jsonb not null,         -- [{front9,back9,total}, ...]
  pars_snapshot    int[] not null,         -- pars AS PLAYED (history-safe)
  status           text not null default 'completed'
                     check (status in ('completed','abandoned')),
  started_at       timestamptz,
  finished_at      timestamptz,
  duration_seconds int generated always as (
                     case when finished_at is not null and started_at is not null
                          then greatest(0, extract(epoch from (finished_at - started_at))::int)
                          else null end) stored,
  won_prize        boolean not null default false,
  created_at       timestamptz not null default now()
);
create index if not exists games_location_created_idx
  on scorecard.games(location_id, created_at);

-- =====================================================================
-- 3. scorecard.newsletter_signups  (explicit opt-in only)
-- =====================================================================
create table if not exists scorecard.newsletter_signups (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  location_id uuid references public.locations(id) on delete set null,
  consent     boolean not null,
  source      text,
  created_at  timestamptz not null default now(),
  constraint consent_required check (consent = true),
  constraint email_basic_chk  check (position('@' in email) > 1)
);

-- =====================================================================
-- 4. scorecard.feedback  (post-game stars; anonymous by default)
-- =====================================================================
create table if not exists scorecard.feedback (
  id          uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations(id) on delete restrict,
  game_id     uuid references scorecard.games(id) on delete set null,
  stars       int  not null check (stars between 1 and 5),
  comment     text,
  contact     text,
  created_at  timestamptz not null default now()
);
create index if not exists feedback_location_idx
  on scorecard.feedback(location_id, created_at);

-- =====================================================================
-- 5. scorecard.promotions  (per-location or global; events too)
-- =====================================================================
create table if not exists scorecard.promotions (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  body        text,
  image_url   text,
  link_url    text,
  scope       text not null default 'location'
                check (scope in ('location','global')),
  location_id uuid references public.locations(id) on delete cascade,
  type        text not null default 'promo' check (type in ('promo','event')),
  starts_at   timestamptz,
  ends_at     timestamptz,
  is_active   boolean not null default true,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  -- global promos carry no location; location promos must have one
  constraint promo_scope_loc_chk check (
    (scope = 'global'   and location_id is null) or
    (scope = 'location' and location_id is not null))
);

-- =====================================================================
-- 6. scorecard.secret_prize_config  (per-location params; admin-set)
-- =====================================================================
create table if not exists scorecard.secret_prize_config (
  location_id           uuid primary key references public.locations(id) on delete cascade,
  enabled               boolean not null default false,
  hole_mode             text not null default 'random' check (hole_mode in ('fixed','random')),
  fixed_hole            int check (fixed_hole between 1 and 18),
  score_mode            text not null default 'exact'
                          check (score_mode in ('hole_in_one','exact','range')),
  target_score          int,
  win_rate              numeric not null default 0.05 check (win_rate >= 0 and win_rate <= 1),
  daily_cap             int not null default 5 check (daily_cap >= 0),
  min_duration_seconds  int not null default 900 check (min_duration_seconds >= 0),
  device_cooldown_seconds int not null default 0 check (device_cooldown_seconds >= 0),
  onboarding_teaser     boolean not null default true,
  updated_at            timestamptz not null default now()
);

-- =====================================================================
-- 7. scorecard.secret_prize_state  (CURRENT live secret; rotates on win)
--    NEVER readable by anon. Touched only by the win-eval edge function.
-- =====================================================================
create table if not exists scorecard.secret_prize_state (
  location_id     uuid primary key references public.locations(id) on delete cascade,
  active_hole     int  not null check (active_hole between 1 and 18),
  active_score    int  not null,
  awarded_today   int  not null default 0,
  award_date      date not null default current_date,
  last_rotated_at timestamptz not null default now()
);

-- =====================================================================
-- 8. scorecard.prize_pool  (tiered prizes; physical, no expiry)
-- =====================================================================
create table if not exists scorecard.prize_pool (
  id          uuid primary key default gen_random_uuid(),
  location_id uuid references public.locations(id) on delete cascade, -- null = global prize
  label       text not null,
  value       numeric not null default 0,
  weight      int not null default 1 check (weight >= 0),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

-- =====================================================================
-- 9. scorecard.prize_wins  (instant confirm; the ONE place a name lives)
-- =====================================================================
create table if not exists scorecard.prize_wins (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,           -- short, shown on win screen
  qr_payload    text,                            -- future scanning
  game_id       uuid references scorecard.games(id) on delete set null,
  location_id   uuid not null references public.locations(id) on delete restrict,
  winner_name   text not null,                   -- deliberate exception to anonymity
  winning_hole  int  not null,
  winning_score int  not null,
  prize_id      uuid references scorecard.prize_pool(id) on delete set null,
  prize_label   text not null,                   -- snapshot
  prize_value   numeric not null default 0,      -- snapshot
  status        text not null default 'awaiting_confirm'
                  check (status in ('awaiting_confirm','confirmed')),
  confirmed_at  timestamptz,
  confirmed_by  uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists prize_wins_location_idx
  on scorecard.prize_wins(location_id, created_at);

-- =====================================================================
-- 10. scorecard.role_permissions  (DATA-DRIVEN capability matrix)
--     Admin edits this; nothing is hardcoded. role x capability -> allowed.
-- =====================================================================
create table if not exists scorecard.role_permissions (
  role       text not null check (role in
               ('admin','owner','location_manager','team_leader','team_member','game_tech')),
  capability text not null,   -- e.g. 'redeem_prize','manage_promos','configure_location',
                              --      'configure_secret_prize','view_stats','grant_access'
  allowed    boolean not null default false,
  primary key (role, capability)
);

-- sensible starting matrix (all editable later by admin)
insert into scorecard.role_permissions(role,capability,allowed) values
  ('admin','configure_location',true),
  ('admin','manage_promos',true),
  ('admin','configure_secret_prize',true),
  ('admin','view_stats',true),
  ('admin','redeem_prize',true),
  ('admin','grant_access',true),
  ('owner','configure_location',true),
  ('owner','manage_promos',true),
  ('owner','configure_secret_prize',true),
  ('owner','view_stats',true),
  ('owner','redeem_prize',true),
  ('owner','grant_access',true),
  ('location_manager','manage_promos',true),
  ('location_manager','view_stats',true),
  ('location_manager','redeem_prize',true),
  ('team_leader','redeem_prize',true),
  ('team_leader','view_stats',true),
  ('team_member','redeem_prize',true)
on conflict (role,capability) do nothing;

-- helper: does the current user have a capability (per the matrix)?
create or replace function scorecard.has_capability(cap text)
returns boolean language sql stable security definer
set search_path = scorecard, public, gz360_auth as $$
  select coalesce((
    select rp.allowed
    from scorecard.role_permissions rp
    where rp.capability = cap
      and rp.role = (select role from public.profiles where id = auth.uid())
  ), false);
$$;

-- =====================================================================
-- 11. PUBLIC READ-ONLY VIEW for the anonymous guest app
--     Exposes ONLY what guests need: visible locations + name + pars +
--     rules. No profiles, no internal location columns, no secrets.
-- =====================================================================
create or replace view scorecard.public_locations
with (security_invoker = false) as
  select l.id            as location_id,
         l.name          as name,
         ls.pars         as pars,
         ls.hole_count   as hole_count,
         ls.rules_text   as rules_text,
         ls.scorecard_status as scorecard_status
  from public.locations l
  join scorecard.location_settings ls on ls.location_id = l.id
  where ls.scorecard_status in ('active','coming_soon');

-- Public active promotions view (currently-active only)
create or replace view scorecard.public_promotions
with (security_invoker = false) as
  select p.id, p.title, p.body, p.image_url, p.link_url, p.type,
         p.scope, p.location_id
  from scorecard.promotions p
  where p.is_active = true
    and (p.starts_at is null or p.starts_at <= now())
    and (p.ends_at   is null or p.ends_at   >= now())
    -- only surface promos for VISIBLE locations:
    --  * global promos always ok
    --  * location promos only if that location is active/coming_soon
    and (
      p.scope = 'global'
      or exists (
        select 1 from scorecard.location_settings ls
        where ls.location_id = p.location_id
          and ls.scorecard_status in ('active','coming_soon')
      )
    );

commit;
