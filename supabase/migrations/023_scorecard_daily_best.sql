-- Migration 023: anon-callable "daily best" for the guest results screen.
-- Returns the lowest INDIVIDUAL player total carded at one location since midnight
-- (America/Toronto), among COMPLETED, non-test games — and only counting players
-- who finished all 18 holes (no null holes), so a quit-early card can't set an
-- unbeatable low. Returns null when no qualifying score exists. Leaks ONLY the
-- integer (no names, ids, or per-row data). Anon-executable, mirroring
-- is_secret_score_redeemed (017). Apply in the Supabase SQL Editor as the
-- privileged role.

create or replace function scorecard.daily_best(p_location_id uuid)
returns integer
language sql
stable
security definer
set search_path = scorecard, public
as $$
  select min((elem.t ->> 'total')::int)::int
  from scorecard.games g
  cross join lateral (
    select tt.val as t, ss.val as s
    from jsonb_array_elements(g.totals) with ordinality tt(val, idx)
    join jsonb_array_elements(g.scores) with ordinality ss(val, idx)
      on tt.idx = ss.idx
  ) elem
  where g.location_id = p_location_id
    and g.status = 'completed'
    and g.is_test = false
    and g.created_at >= (date_trunc('day', now() at time zone 'America/Toronto')
                           at time zone 'America/Toronto')
    and jsonb_array_length(elem.s) = 18
    and not exists (
      select 1
      from jsonb_array_elements(elem.s) as h(val)
      where h.val = 'null'::jsonb or h.val is null
    );
$$;

revoke all on function scorecard.daily_best(uuid) from public;
grant execute on function scorecard.daily_best(uuid) to anon, authenticated;
