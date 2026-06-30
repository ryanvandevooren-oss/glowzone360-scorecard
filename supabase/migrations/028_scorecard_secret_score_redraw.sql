-- =====================================================================
-- 028_scorecard_secret_score_redraw.sql
-- Manual "redraw the secret" for staff: a manager rotates a location's LIVE
-- secret on demand (current hole feels stale), with an audit trail.
--
-- Builds on:
--   010  secret_score_config / secret_score_current tables + anon-locked RLS
--   011  engine (SECURITY DEFINER pattern; the function OWNER bypasses RLS)
--   scorecard.draw_secret_score(p_location_id, p_pool_mode, p_holes, p_scores,
--        OUT o_hole, OUT o_score)  -- existing weighted-draw helper, REUSED here
--
-- APPLY as the SAME privileged role that owns the other scorecard SECURITY
-- DEFINER functions, so ownership / RLS-bypass match (see 011 NOTE A).
-- =====================================================================

begin;

-- ═══════════════════════════════════════════════════════════════════
-- 1. Audit table — one row per SUCCESSFUL manual redraw
-- ═══════════════════════════════════════════════════════════════════
create table if not exists scorecard.secret_score_redraws (
  id          uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations(id) on delete cascade,
  actor_role  text,             -- gz_current_role() at redraw time (may be null)
  actor_uid   uuid,             -- auth.uid() of the staff member
  old_hole    int,              -- previous secret (null if none had been drawn yet)
  old_score   int,
  new_hole    int  not null,    -- newly drawn secret (always populated on success)
  new_score   int  not null,
  created_at  timestamptz not null default now()
);
create index if not exists secret_score_redraws_loc_created_idx
  on scorecard.secret_score_redraws(location_id, created_at desc);

-- ═══════════════════════════════════════════════════════════════════
-- 2. RLS + grants on the audit table  (mirrors secret_score_wins, 011)
-- ═══════════════════════════════════════════════════════════════════
-- anon: NONE. The definer RPC inserts here (bypassing RLS as owner); staff who
-- can configure secret score at the location may READ the trail. No client
-- INSERT/UPDATE/DELETE grant — rows are created only by redraw_secret_score.
alter table scorecard.secret_score_redraws enable row level security;

grant usage  on schema scorecard to authenticated;                 -- idempotent
grant select on scorecard.secret_score_redraws to authenticated;
revoke all   on scorecard.secret_score_redraws from anon, public;

create policy staff_read_secret_redraws on scorecard.secret_score_redraws
  for select to authenticated
  using (scorecard.has_capability('configure_secret_score')
         and gz360_auth.gz_can_manage_location(location_id));
-- service_role / table owner bypass RLS automatically — no policy needed.

-- ═══════════════════════════════════════════════════════════════════
-- 3. redraw_secret_score(p_location_id) — staff-only manual rotation
-- ═══════════════════════════════════════════════════════════════════
-- Returns jsonb:
--   {ok:true,  hole, score, drawn_at}     success
--   {ok:false, reason:'disabled'}         feature off / no config row
--   {ok:false, reason:'empty_pool'}       nothing to draw (NULLs never written)
--   {ok:false, reason:'pool_too_small'}   pool can't produce a DIFFERENT secret
-- RAISES (42501) when the caller lacks capability / location rights.
create or replace function scorecard.redraw_secret_score(p_location_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = scorecard, public
as $$
declare
  v_enabled    boolean;
  v_pool_mode  text;
  v_holes      int[];
  v_scores     int[];
  v_old_hole   int;
  v_old_score  int;
  v_new_hole   int;
  v_new_score  int;
  v_drawn_at   timestamptz;
  v_actor_role text;
  v_actor_uid  uuid;
  v_try        int;
begin
  -- (1) AUTHORIZE — same gate as a per-location config write. auth.uid() and the
  -- role helpers still reflect the CALLER inside a SECURITY DEFINER function.
  if not (scorecard.has_capability('configure_secret_score')
          and gz360_auth.gz_can_manage_location(p_location_id)) then
    raise exception 'not authorized to redraw the secret for location %', p_location_id
      using errcode = '42501';
  end if;

  -- (2) Load the location's pool config. Disabled / unconfigured → no redraw.
  select sc.enabled, sc.pool_mode, sc.allowed_holes, sc.allowed_scores
    into v_enabled, v_pool_mode, v_holes, v_scores
    from scorecard.secret_score_config sc
   where sc.location_id = p_location_id;

  if not found or v_enabled is distinct from true then
    return jsonb_build_object('ok', false, 'reason', 'disabled');
  end if;

  -- Serialize against the engine's win-rotation for this location (same lock key
  -- 011 uses) so a concurrent win and a manual redraw can't clobber each other.
  perform pg_advisory_xact_lock(hashtext(p_location_id::text));

  -- (3) Current secret, if any (null on a location that has never drawn).
  select cur.hole, cur.score
    into v_old_hole, v_old_score
    from scorecard.secret_score_current cur
   where cur.location_id = p_location_id;

  -- (4) Draw a NEW, DIFFERENT secret — REUSE draw_secret_score, up to 10 tries.
  for v_try in 1..10 loop
    select o_hole, o_score
      into v_new_hole, v_new_score
      from scorecard.draw_secret_score(p_location_id, v_pool_mode, v_holes, v_scores);

    if v_new_hole is null or v_new_score is null then
      -- Empty pool: nothing to draw. Do NOT write NULLs (columns are NOT NULL).
      return jsonb_build_object('ok', false, 'reason', 'empty_pool');
    end if;

    exit when v_old_hole is null
           or v_new_hole  <> v_old_hole
           or v_new_score <> v_old_score;
  end loop;

  -- Every draw equalled the current secret → pool too small to differ.
  if v_old_hole is not null
     and v_new_hole  = v_old_hole
     and v_new_score = v_old_score then
    return jsonb_build_object('ok', false, 'reason', 'pool_too_small');
  end if;

  -- (5) Write the new secret (insert-or-update the singleton row).
  insert into scorecard.secret_score_current (location_id, hole, score, drawn_at)
  values (p_location_id, v_new_hole, v_new_score, now())
  on conflict (location_id) do update
    set hole     = excluded.hole,
        score    = excluded.score,
        drawn_at = excluded.drawn_at
  returning drawn_at into v_drawn_at;

  -- (6) Audit the redraw (old → new + actor).
  v_actor_role := gz360_auth.gz_current_role();
  v_actor_uid  := auth.uid();
  insert into scorecard.secret_score_redraws
    (location_id, actor_role, actor_uid, old_hole, old_score, new_hole, new_score)
  values
    (p_location_id, v_actor_role, v_actor_uid, v_old_hole, v_old_score, v_new_hole, v_new_score);

  -- (7) Hand the new secret back so the UI can refresh the live-secret banner.
  return jsonb_build_object(
    'ok',       true,
    'hole',     v_new_hole,
    'score',    v_new_score,
    'drawn_at', v_drawn_at);
end;
$$;

-- ═══════════════════════════════════════════════════════════════════
-- 4. Grants — STAFF ONLY (never anon, unlike evaluate_secret_score)
-- ═══════════════════════════════════════════════════════════════════
revoke all     on function scorecard.redraw_secret_score(uuid) from public;
grant  execute on function scorecard.redraw_secret_score(uuid) to authenticated;

commit;

-- =====================================================================
-- ROLLBACK (manual):
--   drop function if exists scorecard.redraw_secret_score(uuid);
--   drop table    if exists scorecard.secret_score_redraws;
-- =====================================================================
