import { NextResponse } from "next/server";
import { getPool, isDatabaseConfigured } from "@/lib/db/pool";

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

  return NextResponse.json({
    status: "ok",
    database,
    timestamp: new Date().toISOString(),
  });
}
