import { describe, it, expect, afterAll } from "vitest";
import { NextRequest } from "next/server";
import { POST as POST_BATCH } from "@/app/api/token-profiles/route";
import { POST as POST_SINGLE, GET as GET_SINGLE } from "@/app/api/token-profile/route";
import { getPool } from "@/lib/db/pool";
import { MAX_TICKER_COUNT } from "@/lib/constants";

function makeBatchRequest(body: unknown) {
  return new NextRequest("http://localhost/api/token-profiles", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function makeSinglePostRequest(body: unknown) {
  return new NextRequest("http://localhost/api/token-profile", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

// A distinct tokenId range (920000+) from token-profile/route.test.ts's own
// 910000+ range, so the two test files' real database writes can never
// collide or interfere with each other's assertions.
describe("app/api/token-profiles route (batch, POST)", () => {
  afterAll(async () => {
    const pool = getPool();
    await pool.query("DELETE FROM token_profiles WHERE token_id >= 920000 AND token_id < 930000");
    await pool.end();
  });

  it("invalid JSON body returns 400, not a 500 crash", async () => {
    const res = await POST_BATCH(makeBatchRequest("{not valid json"));
    expect(res.status).toBe(400);
  });

  it("a body without a tokenIds array returns 400", async () => {
    const res = await POST_BATCH(makeBatchRequest({ notTokenIds: [1, 2] }));
    expect(res.status).toBe(400);
  });

  it("an empty tokenIds array returns 400", async () => {
    const res = await POST_BATCH(makeBatchRequest({ tokenIds: [] }));
    expect(res.status).toBe(400);
  });

  it("a non-numeric id in the list returns 400", async () => {
    const res = await POST_BATCH(makeBatchRequest({ tokenIds: [920001, "not-a-number"] }));
    expect(res.status).toBe(400);
  });

  it(`more than MAX_TICKER_COUNT (${MAX_TICKER_COUNT}) ids returns 400 - the real, contract-enforced ceiling, not the old artificial 500 cap`, async () => {
    const tooMany = Array.from({ length: MAX_TICKER_COUNT + 1 }, (_, i) => i);
    const res = await POST_BATCH(makeBatchRequest({ tokenIds: tooMany }));
    expect(res.status).toBe(400);
  });

  it(`exactly MAX_TICKER_COUNT (${MAX_TICKER_COUNT}) ids is accepted - the full real collection size never gets silently truncated the way a 500-id cap would`, async () => {
    const fullCollection = Array.from({ length: MAX_TICKER_COUNT }, (_, i) => i);
    const res = await POST_BATCH(makeBatchRequest({ tokenIds: fullCollection }));
    expect(res.status).toBe(200);
  });

  it("tokenIds with no saved profiles returns an empty profiles array, never an error", async () => {
    const res = await POST_BATCH(makeBatchRequest({ tokenIds: [920002, 920003] }));
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.profiles).toEqual([]);
  });

  it("returns only the profiles that actually exist, correctly matched to their own tokenId - never a profile for a tokenId that was never saved", async () => {
    await POST_SINGLE(makeSinglePostRequest({ tokenId: 920010, displayName: "Batch Token A", imageUrl: "/uploads/a.png" }));
    await POST_SINGLE(makeSinglePostRequest({ tokenId: 920012, displayName: "Batch Token C" }));
    // 920011 deliberately has no saved profile.

    const res = await POST_BATCH(makeBatchRequest({ tokenIds: [920010, 920011, 920012] }));
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.profiles).toHaveLength(2);

    const byId = new Map(data.profiles.map((p: { tokenId: number }) => [p.tokenId, p]));
    expect(byId.get(920010)).toMatchObject({ tokenId: 920010, displayName: "Batch Token A", imageUrl: "/uploads/a.png" });
    expect(byId.get(920012)).toMatchObject({ tokenId: 920012, displayName: "Batch Token C" });
    expect(byId.has(920011)).toBe(false);
  });

  it("a batch POST returns the identical data a single GET would for the same tokenId - the batch path is not a second, divergent read implementation", async () => {
    await POST_SINGLE(makeSinglePostRequest({ tokenId: 920020, displayName: "Parity Check", websiteUrl: "https://example.com" }));

    const singleRes = await GET_SINGLE(new NextRequest("http://localhost/api/token-profile?tokenId=920020"));
    const singleData = await singleRes.json();

    const batchRes = await POST_BATCH(makeBatchRequest({ tokenIds: [920020] }));
    const batchData = await batchRes.json();

    expect(batchData.profiles[0]).toEqual(singleData.profile);
  });
});
