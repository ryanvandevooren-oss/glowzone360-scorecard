-- =====================================================================
-- 030_scorecard_get_current_secret.sql
-- Passphrase-gated read of the live secret (hole/score/drawn time) for the
-- /redeem app's secret strip. Anon can't read scorecard.secret_score_current
-- directly, so this SECURITY DEFINER RPC verifies the per-location passphrase
-- (reusing the 029 helper) and returns the current secret — leaking nothing on
-- a bad passphrase. Mirrors the 029 passphrase-tier RPC pattern exactly.
--
-- APPLY as the SAME privileged role that owns the other scorecard SECURITY
-- DEFINER objects (010/011/012/028/029), so ownership / RLS-bypass match.
-- =====================================================================

begin;

-- ═══════════════════════════════════════════════════════════════════
-- Passphrase-tier RPC: current live secret for one location.
-- ═══════════════════════════════════════════════════════════════════
create or replace function scorecard.get_current_secret(p_location_id uuid, p_passphrase text)
returns jsonb
language plpgsql
stable
security definer
set search_path = scorecard, public
as $$
declare
  v_hole     int;
  v_score    int;
  v_drawn_at timestamptz;
begin
  if not scorecard._redemption_passphrase_ok(p_location_id, p_passphrase) then
    return jsonb_build_object('ok', false);
  end if;

  select cur.hole, cur.score, cur.drawn_at
    into v_hole, v_score, v_drawn_at
    from scorecard.secret_score_current cur
   where cur.location_id = p_location_id;

  if not found then
    return jsonb_build_object('ok', true, 'has_secret', false);
  end if;

  return jsonb_build_object(
    'ok', true,
    'has_secret', true,
    'hole', v_hole,
    'score', v_score,
    'drawn_at', v_drawn_at);
end;
$$;

revoke all     on function scorecard.get_current_secret(uuid, text) from public;
grant  execute on function scorecard.get_current_secret(uuid, text) to anon, authenticated;

commit;
