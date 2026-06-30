-- =====================================================================
-- 029_scorecard_redemption_passphrase.sql
-- Data/auth layer for the /redeem mini-app: per-location passphrase login
-- (anon tier) + capability-gated elevated actions (refresh / reverse).
--
-- APPLY as the SAME privileged role that owns the other scorecard SECURITY
-- DEFINER objects (010/011/012/028), so ownership / RLS-bypass match.
-- =====================================================================

begin;

-- ═══════════════════════════════════════════════════════════════════
-- 1. Extension: pgcrypto (crypt / gen_salt). No-op if already present.
-- ═══════════════════════════════════════════════════════════════════
create extension if not exists pgcrypto with schema extensions;

-- ═══════════════════════════════════════════════════════════════════
-- 2. Per-location passphrase (bcrypt hash). DEFINER-ONLY.
-- ═══════════════════════════════════════════════════════════════════
create table if not exists scorecard.secret_score_redemption_auth (
  location_id     uuid primary key references public.locations(id) on delete cascade,
  passphrase_hash text not null,
  set_by          uuid,
  set_at          timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

alter table scorecard.secret_score_redemption_auth enable row level security;
revoke all on scorecard.secret_score_redemption_auth from anon, public, authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- 3. secret_score_wins: tier marker (additive, nullable).
-- ═══════════════════════════════════════════════════════════════════
alter table scorecard.secret_score_wins
  add column if not exists redeemed_via text;

-- ═══════════════════════════════════════════════════════════════════
-- 4. Redemption / undo audit log.
-- ═══════════════════════════════════════════════════════════════════
create table if not exists scorecard.secret_score_redemption_log (
  id          uuid primary key default gen_random_uuid(),
  win_id      uuid,
  location_id uuid not null references public.locations(id) on delete cascade,
  action      text not null check (action in ('redeem','undo_immediate','undo_elevated')),
  tier        text not null check (tier in ('passphrase','elevated')),
  actor_uid   uuid,
  created_at  timestamptz not null default now()
);
create index if not exists secret_score_redemption_log_loc_created_idx
  on scorecard.secret_score_redemption_log(location_id, created_at desc);

alter table scorecard.secret_score_redemption_log enable row level security;
grant usage  on schema scorecard to authenticated;
grant select on scorecard.secret_score_redemption_log to authenticated;
revoke all   on scorecard.secret_score_redemption_log from anon, public;

create policy staff_read_redemption_log on scorecard.secret_score_redemption_log
  for select to authenticated
  using ((scorecard.has_capability('redeem_secret_score')
          or scorecard.has_capability('override_secret_redemption'))
         and gz360_auth.gz_can_access_location(location_id));

-- ═══════════════════════════════════════════════════════════════════
-- 5. Capability seed — initial defaults for the editable matrix.
-- ═══════════════════════════════════════════════════════════════════
insert into scorecard.role_permissions(role, capability, allowed) values
  ('admin',            'override_secret_redemption', true),
  ('owner',            'override_secret_redemption', true),
  ('location_manager', 'override_secret_redemption', true),
  ('team_leader',      'override_secret_redemption', true)
on conflict (role, capability) do nothing;

-- ═══════════════════════════════════════════════════════════════════
-- 6. Internal helper: single-row passphrase verify (bcrypt).
-- ═══════════════════════════════════════════════════════════════════
create or replace function scorecard._redemption_passphrase_ok(p_location_id uuid, p_passphrase text)
returns boolean
language sql
stable
security definer
set search_path = scorecard, public, extensions
as $$
  select exists (
    select 1
    from scorecard.secret_score_redemption_auth a
    where a.location_id = p_location_id
      and p_passphrase is not null
      and a.passphrase_hash = crypt(p_passphrase, a.passphrase_hash)
  );
$$;
revoke all on function scorecard._redemption_passphrase_ok(uuid, text) from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- 7. ADMIN RPC: set / rotate a location's redemption passphrase.
-- ═══════════════════════════════════════════════════════════════════
create or replace function scorecard.set_redemption_passphrase(p_location_id uuid, p_passphrase text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = scorecard, public, extensions
as $$
begin
  if not (scorecard.has_capability('configure_secret_score')
          and gz360_auth.gz_can_manage_location(p_location_id)) then
    raise exception 'not authorized to set the redemption passphrase for location %', p_location_id
      using errcode = '42501';
  end if;
  if p_passphrase is null or length(btrim(p_passphrase)) < 4 then
    return jsonb_build_object('ok', false, 'reason', 'too_short');
  end if;
  insert into scorecard.secret_score_redemption_auth
    (location_id, passphrase_hash, set_by, set_at, updated_at)
  values
    (p_location_id, crypt(p_passphrase, gen_salt('bf')), auth.uid(), now(), now())
  on conflict (location_id) do update
    set passphrase_hash = excluded.passphrase_hash,
        set_by          = excluded.set_by,
        updated_at      = now();
  return jsonb_build_object('ok', true);
end;
$$;
revoke all     on function scorecard.set_redemption_passphrase(uuid, text) from public, anon;
grant  execute on function scorecard.set_redemption_passphrase(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- 8. ANON (passphrase-tier) RPCs — pick-location-then-passphrase.
-- ═══════════════════════════════════════════════════════════════════

-- 8a. Verify → matched location or {ok:false}.
create or replace function scorecard.verify_redemption_passphrase(p_location_id uuid, p_passphrase text)
returns jsonb
language plpgsql
stable
security definer
set search_path = scorecard, public
as $$
declare v_name text;
begin
  if not scorecard._redemption_passphrase_ok(p_location_id, p_passphrase) then
    return jsonb_build_object('ok', false);
  end if;
  select l.name into v_name from public.locations l where l.id = p_location_id;
  return jsonb_build_object('ok', true, 'location_id', p_location_id, 'location_name', v_name);
end;
$$;

-- 8b. Today's wins (Toronto midnight).
create or replace function scorecard.list_today_wins(p_location_id uuid, p_passphrase text)
returns table (
  id                  uuid,
  hole                int,
  score               int,
  prize_name_snapshot text,
  prize_image_url     text,
  redeem_code         text,
  redeemed            boolean,
  redeemed_at         timestamptz,
  created_at          timestamptz
)
language plpgsql
stable
security definer
set search_path = scorecard, public
as $$
begin
  if not scorecard._redemption_passphrase_ok(p_location_id, p_passphrase) then
    return;
  end if;
  return query
    select w.id, w.hole, w.score, w.prize_name_snapshot,
           p.image_url,
           w.redeem_code, w.redeemed, w.redeemed_at, w.created_at
    from scorecard.secret_score_wins w
    left join scorecard.secret_score_prizes p on p.id = w.prize_id
    where w.location_id = p_location_id
      and w.created_at >= (date_trunc('day', now() at time zone 'America/Toronto')
                             at time zone 'America/Toronto')
    order by w.created_at desc;
end;
$$;

-- 8c. Redeem a win (race-guarded).
create or replace function scorecard.redeem_via_passphrase(p_location_id uuid, p_passphrase text, p_win_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = scorecard, public
as $$
declare v_changed int;
begin
  if not scorecard._redemption_passphrase_ok(p_location_id, p_passphrase) then
    return jsonb_build_object('ok', false, 'reason', 'unauthorized');
  end if;
  update scorecard.secret_score_wins
     set redeemed = true, redeemed_at = now(), redeemed_via = 'passphrase'
   where id = p_win_id and location_id = p_location_id and redeemed = false;
  get diagnostics v_changed = row_count;
  if v_changed > 0 then
    insert into scorecard.secret_score_redemption_log (win_id, location_id, action, tier, actor_uid)
    values (p_win_id, p_location_id, 'redeem', 'passphrase', null);
  end if;
  return jsonb_build_object('ok', true, 'changed', v_changed > 0);
end;
$$;

-- 8d. 15-second no-password undo (passphrase-tier only).
create or replace function scorecard.undo_redeem_immediate(p_location_id uuid, p_passphrase text, p_win_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = scorecard, public
as $$
declare v_changed int;
begin
  if not scorecard._redemption_passphrase_ok(p_location_id, p_passphrase) then
    return jsonb_build_object('ok', false, 'reason', 'unauthorized');
  end if;
  update scorecard.secret_score_wins
     set redeemed = false, redeemed_at = null, redeemed_via = null, redeemed_by = null
   where id = p_win_id
     and location_id = p_location_id
     and redeemed = true
     and redeemed_via = 'passphrase'
     and redeemed_at >= now() - interval '15 seconds';
  get diagnostics v_changed = row_count;
  if v_changed > 0 then
    insert into scorecard.secret_score_redemption_log (win_id, location_id, action, tier, actor_uid)
    values (p_win_id, p_location_id, 'undo_immediate', 'passphrase', null);
  end if;
  return jsonb_build_object('ok', true, 'changed', v_changed > 0);
end;
$$;

revoke all on function scorecard.verify_redemption_passphrase(uuid, text)        from public;
revoke all on function scorecard.list_today_wins(uuid, text)                     from public;
revoke all on function scorecard.redeem_via_passphrase(uuid, text, uuid)         from public;
revoke all on function scorecard.undo_redeem_immediate(uuid, text, uuid)         from public;
grant execute on function scorecard.verify_redemption_passphrase(uuid, text)     to anon, authenticated;
grant execute on function scorecard.list_today_wins(uuid, text)                  to anon, authenticated;
grant execute on function scorecard.redeem_via_passphrase(uuid, text, uuid)      to anon, authenticated;
grant execute on function scorecard.undo_redeem_immediate(uuid, text, uuid)      to anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- 9. ELEVATED (authed-tier) RPCs.
-- ═══════════════════════════════════════════════════════════════════

-- 9a. Refresh the live secret from the desk (override_secret_redemption gate).
create or replace function scorecard.refresh_secret_from_desk(p_location_id uuid)
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
  if not (scorecard.has_capability('override_secret_redemption')
          and gz360_auth.gz_can_access_location(p_location_id)) then
    raise exception 'not authorized to refresh the secret for location %', p_location_id
      using errcode = '42501';
  end if;

  select sc.enabled, sc.pool_mode, sc.allowed_holes, sc.allowed_scores
    into v_enabled, v_pool_mode, v_holes, v_scores
    from scorecard.secret_score_config sc
   where sc.location_id = p_location_id;
  if not found or v_enabled is distinct from true then
    return jsonb_build_object('ok', false, 'reason', 'disabled');
  end if;

  perform pg_advisory_xact_lock(hashtext(p_location_id::text));

  select cur.hole, cur.score into v_old_hole, v_old_score
    from scorecard.secret_score_current cur
   where cur.location_id = p_location_id;

  for v_try in 1..10 loop
    select o_hole, o_score into v_new_hole, v_new_score
      from scorecard.draw_secret_score(p_location_id, v_pool_mode, v_holes, v_scores);
    if v_new_hole is null or v_new_score is null then
      return jsonb_build_object('ok', false, 'reason', 'empty_pool');
    end if;
    exit when v_old_hole is null
           or v_new_hole  <> v_old_hole
           or v_new_score <> v_old_score;
  end loop;

  if v_old_hole is not null and v_new_hole = v_old_hole and v_new_score = v_old_score then
    return jsonb_build_object('ok', false, 'reason', 'pool_too_small');
  end if;

  insert into scorecard.secret_score_current (location_id, hole, score, drawn_at)
  values (p_location_id, v_new_hole, v_new_score, now())
  on conflict (location_id) do update
    set hole = excluded.hole, score = excluded.score, drawn_at = excluded.drawn_at
  returning drawn_at into v_drawn_at;

  v_actor_role := gz360_auth.gz_current_role();
  v_actor_uid  := auth.uid();
  insert into scorecard.secret_score_redraws
    (location_id, actor_role, actor_uid, old_hole, old_score, new_hole, new_score)
  values
    (p_location_id, v_actor_role, v_actor_uid, v_old_hole, v_old_score, v_new_hole, v_new_score);

  return jsonb_build_object('ok', true, 'hole', v_new_hole, 'score', v_new_score, 'drawn_at', v_drawn_at);
end;
$$;

-- 9b. Reverse an OLDER redemption (override_secret_redemption gate).
create or replace function scorecard.undo_redeem_elevated(p_win_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = scorecard, public
as $$
declare
  v_loc     uuid;
  v_changed int;
begin
  select location_id into v_loc
    from scorecard.secret_score_wins
   where id = p_win_id;
  if v_loc is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  if not (scorecard.has_capability('override_secret_redemption')
          and gz360_auth.gz_can_access_location(v_loc)) then
    raise exception 'not authorized to reverse redemptions for location %', v_loc
      using errcode = '42501';
  end if;

  update scorecard.secret_score_wins
     set redeemed = false, redeemed_at = null, redeemed_via = null, redeemed_by = null
   where id = p_win_id and redeemed = true;
  get diagnostics v_changed = row_count;
  if v_changed > 0 then
    insert into scorecard.secret_score_redemption_log (win_id, location_id, action, tier, actor_uid)
    values (p_win_id, v_loc, 'undo_elevated', 'elevated', auth.uid());
  end if;
  return jsonb_build_object('ok', true, 'changed', v_changed > 0);
end;
$$;

revoke all     on function scorecard.refresh_secret_from_desk(uuid) from public, anon;
revoke all     on function scorecard.undo_redeem_elevated(uuid)     from public, anon;
grant  execute on function scorecard.refresh_secret_from_desk(uuid) to authenticated;
grant  execute on function scorecard.undo_redeem_elevated(uuid)     to authenticated;

commit;
