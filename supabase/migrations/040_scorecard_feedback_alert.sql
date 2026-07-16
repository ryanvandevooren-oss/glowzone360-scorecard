-- =====================================================================
-- 040_scorecard_feedback_alert
--
-- Low-star guest feedback -> location email alert.
--
-- When a guest leaves a 1-3 star rating in scorecard.feedback, an AFTER
-- INSERT trigger fires scorecard.notify_feedback_alert(), which POSTs the
-- new row's id to the `feedback-alert` Edge Function (via pg_net /
-- net.http_post). That function reads the feedback row + the location inbox
-- with the service-role key and emails the location via Resend, then stamps
-- alerted_at for idempotency.
--
-- This migration adds, in order:
--   1. feedback.alerted_at  — timestamptz set once the alert email is sent
--      (the Edge Function's idempotency guard; NULL = not yet alerted).
--   2. service_role grants on the scorecard schema + feedback table.
--      Custom schemas do NOT inherit the automatic service_role grants that
--      the `public` schema gets, so without an explicit `grant usage on
--      schema scorecard` + `grant select, update on scorecard.feedback` the
--      Edge Function's service-role reads/updates return 403 (permission
--      denied) even though it holds the service key.
--   3. scorecard.notify_feedback_alert() — SECURITY DEFINER trigger fn that
--      enqueues the HTTP POST; any failure is logged and swallowed so a
--      failed alert can never break the guest's feedback insert.
--   4. trg_feedback_alert — AFTER INSERT trigger, gated to low-star,
--      non-test rows.
--
-- NOTE: notify_feedback_alert() embeds the project ANON key (used as both
-- the Authorization bearer and apikey for the Edge Function call). If the
-- project's anon/publishable key is ever ROTATED, this function must be
-- updated (re-run a create-or-replace with the new key) or the trigger's
-- calls to the Edge Function will start failing with 401.
-- =====================================================================

-- 1. Idempotency / "alerted" marker.
alter table scorecard.feedback add column if not exists alerted_at timestamptz;

-- 2. service_role access (custom schema needs these explicitly).
grant usage on schema scorecard to service_role;
grant select, update on scorecard.feedback to service_role;

-- 3. Trigger function: enqueue the Edge Function POST for the new feedback row.
create or replace function scorecard.notify_feedback_alert()
returns trigger
language plpgsql
security definer
set search_path to 'scorecard', 'public'
as $$
begin
  begin
    perform net.http_post(
      url     := 'https://qfwqdqlzzolyahjcqmka.supabase.co/functions/v1/feedback-alert',
      body    := jsonb_build_object('feedback_id', new.id),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFmd3FkcWx6em9seWFoamNxbWthIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgzNjU5MTEsImV4cCI6MjA5Mzk0MTkxMX0.pa8JVRj3lpsywOxf762DEpYyRqRDfMRgwEWkx_OUH8M',
        'apikey', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFmd3FkcWx6em9seWFoamNxbWthIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgzNjU5MTEsImV4cCI6MjA5Mzk0MTkxMX0.pa8JVRj3lpsywOxf762DEpYyRqRDfMRgwEWkx_OUH8M'
      )
    );
  exception when others then
    -- Never let alerting break the guest's feedback insert.
    raise log 'feedback-alert enqueue failed for %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

-- 4. AFTER INSERT trigger, gated to low-star, non-test rows.
drop trigger if exists trg_feedback_alert on scorecard.feedback;
create trigger trg_feedback_alert
  after insert on scorecard.feedback
  for each row
  when (new.stars <= 3 and new.is_test = false)
  execute function scorecard.notify_feedback_alert();
