// =====================================================================
// secret-score-check  —  Secret Score win-check edge function
//
// A thin, authenticated wrapper over the SECURITY DEFINER RPC
// scorecard.evaluate_secret_score(uuid). The RPC reads the secret + scores
// server-side and returns ONLY a safe verdict. This function:
//   - validates { game_id } (must be a UUID),
//   - calls the RPC with the ANON key (NO service-role key is used here —
//     the RPC is anon-executable and the secret never leaves Postgres),
//   - returns the RPC's JSON verbatim,
//   - never returns or logs the secret, and never 500s the winner screen
//     (any failure → a clean {won:false} the guest treats as "no win").
//
// SUPABASE_URL and SUPABASE_ANON_KEY are auto-injected into the edge runtime;
// no secrets to configure.
// =====================================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

// Standard UUID shape (any version/variant) — crypto.randomUUID() rounds match.
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const PROD_ORIGIN = "https://scorecard.glowzone360.com";
const LOCALHOST_RE = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

// Reflect the caller's origin only if it's the prod site or localhost;
// otherwise fall back to the prod origin (disallowed browsers get blocked).
function corsHeaders(origin: string | null): Record<string, string> {
  const allow =
    origin && (origin === PROD_ORIGIN || LOCALHOST_RE.test(origin))
      ? origin
      : PROD_ORIGIN;
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Vary": "Origin",
  };
}

function json(body: unknown, status: number, origin: string | null): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders(origin) },
  });
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");

  // CORS preflight.
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(origin) });
  }
  if (req.method !== "POST") {
    return json({ won: false, error: "method_not_allowed" }, 405, origin);
  }

  // --- Validate input -------------------------------------------------
  let game_id: unknown;
  try {
    const body = await req.json();
    game_id = body?.game_id;
  } catch {
    return json({ won: false, error: "invalid_json" }, 400, origin);
  }
  if (typeof game_id !== "string" || !UUID_RE.test(game_id)) {
    return json({ won: false, error: "invalid_game_id" }, 400, origin);
  }

  // --- Call the SECURITY DEFINER RPC with the anon key ----------------
  // PostgREST exposes scorecard-schema RPCs via the Content-Profile header.
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/evaluate_secret_score`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Profile": "scorecard",
        "apikey": ANON_KEY,
        "Authorization": `Bearer ${ANON_KEY}`,
      },
      body: JSON.stringify({ p_game_id: game_id }),
    });

    if (!res.ok) {
      // Log status only — never the response body (defense-in-depth; the RPC
      // doesn't return the secret anyway). Soft-fail so the winner screen is fine.
      console.error("evaluate_secret_score RPC non-OK:", res.status);
      return json({ won: false, error: "eval_failed" }, 200, origin);
    }

    // RPC returns {won:false} or {won:true, prize_name, reveal_text, redeem_code}.
    const result = await res.json();
    return json(result, 200, origin);
  } catch (e) {
    console.error("secret-score-check error:", e instanceof Error ? e.message : "unknown");
    return json({ won: false, error: "internal" }, 200, origin);
  }
});
