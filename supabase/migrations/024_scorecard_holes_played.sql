-- Migration 024: per-round completeness indicator on scorecard.games.
-- holes_played = number of holes where ALL players have a non-null score.
-- A round is "complete" when holes_played = array_length(pars_snapshot, 1).
-- Backfills existing rows from their stored scores so historical data reads
-- honestly. Adds a nullable column (safe for live guest inserts — anon INSERT
-- grant is table-level, policy is row-level, so no RLS change needed).
-- Apply in the Supabase SQL Editor as the privileged role.

alter table scorecard.games
  add column if not exists holes_played int;

update scorecard.games g
set holes_played = sub.cnt
from (
  select
    games.id,
    count(*) filter (where hole_complete) as cnt
  from scorecard.games games
  cross join lateral (
    select
      h.idx,
      not exists (
        select 1
        from jsonb_array_elements(games.scores) as player(arr)
        where (player.arr -> h.idx) is null
           or jsonb_typeof(player.arr -> h.idx) = 'null'
      ) as hole_complete
    from generate_series(0, greatest(coalesce(array_length(games.pars_snapshot, 1), 0) - 1, -1)) as h(idx)
  ) holes
  group by games.id
) sub
where g.id = sub.id
  and g.holes_played is null;
