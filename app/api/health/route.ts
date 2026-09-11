import { NextResponse } from "next/server";
import { getPool, isDatabaseConfigured } from "@/lib/db/pool";

// Without this, Next.js's App Router can treat a GET route handler with no
// obvious per-request signal (no request param used, no cookies()/headers()
// call) as statically renderable, evaluating it once at build time and
// serving that same frozen response forever after - exactly what happened
// here (a stale build-time timestamp in production). force-dynamic makes
// this route run fresh on every single request, which is the entire point
// of a health check.
export const dynamic = "force-dynamic";

export async function GET() {
  let database: "connected" | "not_configured" | "error" = "not_configured";

  if (isDatabaseConfigured()) {
    try {
      await getPool().query("SELECT 1");
      database = "connected";
    } catch {
      // Deliberately no error detail in the response - a health endpoint is
      // often reachable without auth, and a raw connection error can leak
      // internal details (hostnames, driver internals). The server's own
      // logs are the place for that detail, not this response.
      database = "error";
    }
  }

  return NextResponse.json(
    {
      status: "ok",
      database,
      timestamp: new Date().toISOString(),
    },
    {
      // Explicit, in addition to force-dynamic above - defense in depth
      // against any intermediate cache (browser, CDN, reverse proxy) ever
      // serving a stale health response.
      headers: { "Cache-Control": "no-store" },
    }
  );
}
