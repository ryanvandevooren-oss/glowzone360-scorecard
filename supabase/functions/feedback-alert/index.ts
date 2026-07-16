// =====================================================================
// feedback-alert  —  low-star guest feedback → location email alert
//
// Called by a DB trigger (POST { "feedback_id": "<uuid>" }) whenever a
// guest leaves a 1-3 star rating in scorecard.feedback. It reads the row
// with the SERVICE-ROLE key (the guest is anonymous and cannot re-read its
// own feedback under RLS), then emails the location's inbox via Resend.
//
// Every "nothing to do" outcome returns 200 with a JSON reason so the
// trigger treats the call as handled and never retries into a loop. Only a
// genuine transient failure (DB read error, Resend non-2xx) returns 5xx so
// a retry can still succeed; alerted_at is stamped ONLY after a confirmed
// send, giving at-least-once delivery with idempotency.
//
// Env (service-role + Resend key must be configured on this function):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  — auto-injected / project secret
//   RESEND_API_KEY                            — same name the project uses
// =====================================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;

// Standard UUID shape (any version/variant) — matches crypto.randomUUID().
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const RESEND_FROM = "GlowZone 360 Scorecard <scorecard@glowzone360.com>";
const TZ = "America/Toronto";

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// Escape guest-provided text before it lands in the email HTML. Comment and
// contact are untrusted input — never interpolate them raw.
function esc(s: unknown): string {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// "★★☆☆☆ 2 out of 5"
function starsLine(stars: number): string {
  const n = Math.max(0, Math.min(5, stars | 0));
  return "★".repeat(n) + "☆".repeat(5 - n) + ` ${n} out of 5`;
}

function fmtWhen(iso: string | null): string {
  if (!iso) return "unknown time";
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "unknown time";
  return new Intl.DateTimeFormat("en-US", {
    timeZone: TZ,
    dateStyle: "medium",
    timeStyle: "short",
  }).format(d) + " (Toronto time)";
}

// PostgREST helper. `schema` selects the profile header: reads use
// Accept-Profile, writes use Content-Profile. public tables need neither.
function pgHeaders(schema: "scorecard" | "public" | null, write: boolean): Record<string, string> {
  const h: Record<string, string> = {
    apikey: SERVICE_KEY,
    Authorization: `Bearer ${SERVICE_KEY}`,
    "Content-Type": "application/json",
  };
  if (schema === "scorecard") {
    if (write) h["Content-Profile"] = "scorecard";
    else h["Accept-Profile"] = "scorecard";
  }
  return h;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ ok: false, error: "method_not_allowed" }, 405);
  }

  // --- Validate input -------------------------------------------------
  let feedback_id: unknown;
  try {
    const body = await req.json();
    feedback_id = body?.feedback_id;
  } catch {
    return json({ ok: false, error: "invalid_json" }, 400);
  }
  if (typeof feedback_id !== "string" || !UUID_RE.test(feedback_id)) {
    return json({ ok: false, error: "invalid_feedback_id" }, 400);
  }

  try {
    // --- Read the feedback row (service role; anon can't re-read) ------
    const fbRes = await fetch(
      `${SUPABASE_URL}/rest/v1/feedback?id=eq.${feedback_id}` +
        `&select=id,location_id,stars,comment,contact,created_at,is_test,alerted_at`,
      { headers: pgHeaders("scorecard", false) },
    );
    if (!fbRes.ok) {
      // Transient read failure — let the trigger retry.
      console.error("feedback read non-OK:", fbRes.status);
      return json({ ok: false, error: "feedback_read_failed" }, 500);
    }
    const fbRows = await fbRes.json();
    const fb = Array.isArray(fbRows) ? fbRows[0] : null;

    // --- Guards: each 200 so the trigger never retries into a loop -----
    if (!fb) return json({ ok: true, skipped: "not_found" }, 200);
    if (fb.is_test === true) return json({ ok: true, skipped: "is_test" }, 200);
    if (typeof fb.stars !== "number" || fb.stars > 3) {
      return json({ ok: true, skipped: "not_low_star" }, 200);
    }
    if (fb.alerted_at) return json({ ok: true, skipped: "already_alerted" }, 200);

    // --- Resolve the location's name + inbox --------------------------
    if (!fb.location_id) return json({ ok: true, skipped: "no_location" }, 200);
    const locRes = await fetch(
      `${SUPABASE_URL}/rest/v1/locations?id=eq.${fb.location_id}&select=name,email&limit=1`,
      { headers: pgHeaders("public", false) },
    );
    if (!locRes.ok) {
      console.error("location read non-OK:", locRes.status);
      return json({ ok: false, error: "location_read_failed" }, 500);
    }
    const locRows = await locRes.json();
    const loc = Array.isArray(locRows) ? locRows[0] : null;
    const locName: string = (loc && loc.name) || "your location";
    const locEmail: string | null = (loc && loc.email) || null;
    if (!locEmail || !String(locEmail).trim()) {
      return json({ ok: true, skipped: "no_location_email" }, 200);
    }

    // --- Compose + send the email via Resend --------------------------
    const commentBlock = (fb.comment && String(fb.comment).trim())
      ? `<blockquote style="margin:0;padding:12px 16px;border-left:4px solid #d0d3e6;background:#f6f7fb;border-radius:0 8px 8px 0;color:#333;font-size:15px;">${esc(fb.comment)}</blockquote>`
      : `<p style="margin:0;color:#888;font-style:italic;">No comment left.</p>`;

    const contactBlock = (fb.contact && String(fb.contact).trim())
      ? `<p style="margin:0;font-size:17px;font-weight:700;color:#1a5fd0;">${esc(fb.contact)}</p>`
      : `<p style="margin:0;color:#888;font-style:italic;">No contact info left.</p>`;

    const subject = `⭐ ${fb.stars}-star guest feedback — ${locName}`;

    const html = `<!DOCTYPE html>
<html>
<body style="margin:0;padding:24px;background:#eef0f7;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
  <div style="max-width:520px;margin:0 auto;background:#fff;border-radius:14px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.08);">
    <div style="padding:20px 24px;background:#1a1c2e;color:#fff;">
      <div style="font-size:13px;letter-spacing:1px;text-transform:uppercase;opacity:.7;">GlowZone 360 · Guest Feedback</div>
      <div style="font-size:20px;font-weight:800;margin-top:4px;">${esc(locName)}</div>
    </div>
    <div style="padding:24px;">
      <div style="font-size:30px;letter-spacing:3px;color:#f5a623;font-weight:800;text-align:center;">${starsLine(fb.stars)}</div>
      <div style="margin-top:22px;">
        <div style="font-size:12px;font-weight:700;letter-spacing:.5px;text-transform:uppercase;color:#888;margin-bottom:6px;">Comment</div>
        ${commentBlock}
      </div>
      <div style="margin-top:22px;">
        <div style="font-size:12px;font-weight:700;letter-spacing:.5px;text-transform:uppercase;color:#888;margin-bottom:6px;">Contact</div>
        ${contactBlock}
      </div>
      <div style="margin-top:22px;font-size:13px;color:#666;border-top:1px solid #eee;padding-top:16px;">
        <div><strong>Location:</strong> ${esc(locName)}</div>
        <div><strong>Submitted:</strong> ${esc(fmtWhen(fb.created_at))}</div>
      </div>
      <p style="margin:22px 0 0;font-size:15px;font-weight:600;color:#1a1c2e;">If contact info was provided, consider reaching out today.</p>
    </div>
  </div>
</body>
</html>`;

    const sendRes = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: RESEND_FROM,
        to: locEmail,
        subject,
        html,
      }),
    });

    if (!sendRes.ok) {
      // Do NOT stamp alerted_at — leave the row so a retry can deliver.
      console.error("Resend non-OK:", sendRes.status);
      return json({ ok: false, error: "resend_failed", status: sendRes.status }, 500);
    }

    // --- Mark alerted (idempotency). Filter on alerted_at IS NULL so a
    //     concurrent duplicate call can't double-stamp. now() isn't
    //     expressible via PostgREST, so we send the function's UTC clock. ---
    const stampRes = await fetch(
      `${SUPABASE_URL}/rest/v1/feedback?id=eq.${feedback_id}&alerted_at=is.null`,
      {
        method: "PATCH",
        headers: { ...pgHeaders("scorecard", true), Prefer: "return=minimal" },
        body: JSON.stringify({ alerted_at: new Date().toISOString() }),
      },
    );
    if (!stampRes.ok) {
      // Email already went out; log but report success so the trigger
      // doesn't retry and re-send. (Worst case: a rare duplicate email.)
      console.error("alerted_at stamp non-OK:", stampRes.status);
    }

    return json({ ok: true }, 200);
  } catch (e) {
    console.error("feedback-alert error:", e instanceof Error ? e.message : "unknown");
    return json({ ok: false, error: "internal" }, 500);
  }
});
