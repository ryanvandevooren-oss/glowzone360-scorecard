-- =====================================================================
-- 031_scorecard_redemption_passphrase_status.sql
-- Admin-only status check for a location's redemption passphrase: returns
-- ONLY whether one is set and when it was last updated — NEVER the hash.
-- The auth table (scorecard.secret_score_redemption_auth) is RLS-locked with
-- no client SELECT, so this SECURITY DEFINER RPC is the only read path, and it
-- exposes nothing sensitive. Same admin gate as set_redemption_passphrase (029).
--
-- APPLY as the SAME privileged role that owns the other scorecard SECURITY
-- DEFINER objects (010/011/012/028/029/030), so ownership / RLS-bypass match.
-- =====================================================================

begin;

-- ═══════════════════════════════════════════════════════════════════
-- Admin-tier RPC: redemption passphrase status (set / not set + when).
-- ═══════════════════════════════════════════════════════════════════
create or replace function scorecard.redemption_passphrase_status(p_location_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = scorecard, public
as $$
declare
  v_updated_at timestamptz;
begin
  if not (scorecard.has_capability('configure_secret_score')
          and gz360_auth.gz_can_manage_location(p_location_id)) then
    raise exception 'not authorized to view the redemption passphrase status for location %', p_location_id
      using errcode = '42501';
  end if;

  select a.updated_at
    into v_updated_at
    from scorecard.secret_score_redemption_auth a
   where a.location_id = p_location_id;

  if found then
    return jsonb_build_object('is_set', true, 'updated_at', v_updated_at);
  end if;
  return jsonb_build_object('is_set', false);
end;
$$;

revoke all     on function scorecard.redemption_passphrase_status(uuid) from public, anon;
grant  execute on function scorecard.redemption_passphrase_status(uuid) to authenticated;

commit;
