import { describe, it, expect, afterAll } from "vitest";
import { NextRequest } from "next/server";
import { GET as GET_BATCH } from "@/app/api/token-profiles/route";
import { POST } from "@/app/api/token-profile/route";
import { getPool } from "@/lib/db/pool";

function makeBatchRequest(tokenIds: string) {
  return new NextRequest(`http://localhost/api/token-profiles?tokenIds=${tokenIds}`);
}

function makePostRequest(body: unknown) {
  return new NextRequest("http://localhost/api/token-profile", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

// A distinct tokenId range (920000+) from token-profile/route.test.ts's own
// 910000+ range, so the two test files' real database writes can never
// collide or interfere with each other's assertions.
describe("app/api/token-profiles route (batch)", () => {
  afterAll(async () => {
    const pool = getPool();
    await pool.query("DELETE FROM token_profiles WHERE token_id >= 920000 AND token_id < 930000");
    await pool.end();
  });

  it("GET with no tokenIds param returns 400", async () => {
    const res = await GET_BATCH(new NextRequest("http://localhost/api/token-profiles"));
    expect(res.status).toBe(400);
  });

  it("GET with an empty tokenIds param returns 400", async () => {
    const res = await GET_BATCH(makeBatchRequest(""));
    expect(res.status).toBe(400);
  });

  it("GET with a non-numeric id in the list returns 400", async () => {
    const res = await GET_BATCH(makeBatchRequest("920001,not-a-number"));
    expect(res.status).toBe(400);
  });

  it("GET with more than 500 ids returns 400", async () => {
    const tooMany = Array.from({ length: 501 }, (_, i) => 920000 + i).join(",");
    const res = await GET_BATCH(makeBatchRequest(tooMany));
    expect(res.status).toBe(400);
  });

  it("GET for tokenIds with no saved profiles returns an empty profiles array, never an error", async () => {
    const res = await GET_BATCH(makeBatchRequest("920002,920003"));
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.profiles).toEqual([]);
  });

  it("GET returns only the profiles that actually exist, correctly matched to their own tokenId - never a profile for a tokenId that was never saved", async () => {
    await POST(makePostRequest({ tokenId: 920010, displayName: "Batch Token A", imageUrl: "/uploads/a.png" }));
    await POST(makePostRequest({ tokenId: 920012, displayName: "Batch Token C" }));
    // 920011 deliberately has no saved profile.

    const res = await GET_BATCH(makeBatchRequest("920010,920011,920012"));
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.profiles).toHaveLength(2);

    const byId = new Map(data.profiles.map((p: { tokenId: number }) => [p.tokenId, p]));
    expect(byId.get(920010)).toMatchObject({ tokenId: 920010, displayName: "Batch Token A", imageUrl: "/uploads/a.png" });
    expect(byId.get(920012)).toMatchObject({ tokenId: 920012, displayName: "Batch Token C" });
    expect(byId.has(920011)).toBe(false);
  });

  it("a batch GET returns the identical data a single GET would for the same tokenId - the batch path is not a second, divergent read implementation", async () => {
    await POST(makePostRequest({ tokenId: 920020, displayName: "Parity Check", websiteUrl: "https://example.com" }));

    const { GET: GET_SINGLE } = await import("@/app/api/token-profile/route");
    const singleRes = await GET_SINGLE(new NextRequest("http://localhost/api/token-profile?tokenId=920020"));
    const singleData = await singleRes.json();

    const batchRes = await GET_BATCH(makeBatchRequest("920020"));
    const batchData = await batchRes.json();

    expect(batchData.profiles[0]).toEqual(singleData.profile);
  });
});
