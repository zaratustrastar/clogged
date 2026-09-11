import { describe, it, expect, vi, beforeEach } from "vitest";

describe("app/api/health route", () => {
  beforeEach(async () => {
    // getPool() caches a single pool in a true Node global, which correctly
    // persists across module reloads in production (DATABASE_URL never
    // changes at runtime there) - but these tests deliberately change
    // DATABASE_URL between cases, so the cached pool from a previous case
    // must be cleared first or every case after the first would silently
    // reuse the wrong connection.
    const g = global as unknown as { __clogPgPool?: { end?: () => Promise<void> } };
    if (g.__clogPgPool?.end) await g.__clogPgPool.end().catch(() => {});
    g.__clogPgPool = undefined;
  });

  it("reports database: not_configured when DATABASE_URL is unset", async () => {
    vi.resetModules();
    delete process.env.DATABASE_URL;
    const { GET } = await import("@/app/api/health/route");
    const res = await GET();
    const data = await res.json();
    expect(data.status).toBe("ok");
    expect(data.database).toBe("not_configured");
    expect(typeof data.timestamp).toBe("string");
  });

  it("is explicitly marked dynamic and never cacheable, so it always reflects the live server rather than a frozen build-time snapshot", async () => {
    vi.resetModules();
    delete process.env.DATABASE_URL;
    const routeModule = await import("@/app/api/health/route");
    expect(routeModule.dynamic).toBe("force-dynamic");

    const res = await routeModule.GET();
    expect(res.headers.get("Cache-Control")).toBe("no-store");
  });

  it("the timestamp genuinely reflects the moment of the request, not a frozen build-time value", async () => {
    vi.resetModules();
    delete process.env.DATABASE_URL;
    const { GET } = await import("@/app/api/health/route");

    const before = Date.now();
    const res = await GET();
    const data = await res.json();
    const after = Date.now();

    const timestampMs = new Date(data.timestamp).getTime();
    expect(timestampMs).toBeGreaterThanOrEqual(before);
    expect(timestampMs).toBeLessThanOrEqual(after);
  });

  it("reports database: connected against a real reachable database", async () => {
    vi.resetModules();
    process.env.DATABASE_URL = "postgresql://postgres:postgres@localhost:5432/clog_test";
    const { GET } = await import("@/app/api/health/route");
    const res = await GET();
    const data = await res.json();
    expect(data.database).toBe("connected");
  });

  it("never leaks connection error detail in the response body", async () => {
    vi.resetModules();
    process.env.DATABASE_URL = "postgresql://postgres:postgres@localhost:5432/nonexistent_db_xyz";
    const { GET } = await import("@/app/api/health/route");
    const res = await GET();
    const data = await res.json();
    expect(data.database).toBe("error");
    expect(JSON.stringify(data)).not.toMatch(/localhost|postgres:postgres|ECONNREFUSED/i);
  });
});
