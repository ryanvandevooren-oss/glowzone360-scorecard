-- Migration 017: anon-callable Secret Score redemption-status check.
-- Returns ONLY a boolean for one win the guest already holds the code for.
-- Leaks nothing else: not the secret, not the prize, not other wins, not
-- ledger fields. Unknown/blank code -> {is_redeemed:false} (no error, no
-- existence oracle). Apply in Supabase SQL Editor as the privileged role.

create or replace function scorecard.is_secret_score_redeemed(p_redeem_code text)
returns jsonb
language sql
stable
security definer
set search_path = scorecard, public
as $$
  select jsonb_build_object(
    'is_redeemed',
    coalesce(
      (select w.redeemed
         from scorecard.secret_score_wins w
        where w.redeem_code = upper(btrim(p_redeem_code))
        limit 1),
      false)
  );
$$;

revoke all on function scorecard.is_secret_score_redeemed(text) from public;
grant execute on function scorecard.is_secret_score_redeemed(text) to anon, authenticated;
