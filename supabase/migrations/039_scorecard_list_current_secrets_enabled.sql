-- ═══════════════════════════════════════════════════════════════
-- 039_scorecard_list_current_secrets_enabled.sql
-- list_current_secrets: include ENABLED locations that have not
-- yet drawn a secret (null hole/score), restoring the admin
-- strip's "No secret yet" placeholder that the direct-select
-- path used to provide. Same return shape → CREATE OR REPLACE.
-- ═══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION scorecard.list_current_secrets()
 RETURNS TABLE(location_id uuid, hole integer, score integer, drawn_at timestamp with time zone, source text, drawn_by_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'scorecard', 'public'
AS $function$
begin
  if not scorecard.has_capability('redeem_secret_score') then
    return;
  end if;
  return query
    select cfg.location_id, cur.hole, cur.score, cur.drawn_at,
           cur.source,
           coalesce(pr.preferred_name, pr.name)
      from scorecard.secret_score_config cfg
      left join scorecard.secret_score_current cur
             on cur.location_id = cfg.location_id
      left join public.profiles pr on pr.id = cur.drawn_by
     where cfg.enabled
       and gz360_auth.gz_can_access_location(cfg.location_id);
end;
$function$;
