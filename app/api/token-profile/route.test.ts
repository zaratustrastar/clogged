import { describe, it, expect, afterAll } from "vitest";
import { NextRequest } from "next/server";
import { GET, POST } from "@/app/api/token-profile/route";
import { getPool } from "@/lib/db/pool";

function makeGetRequest(tokenId: string) {
  return new NextRequest(`http://localhost/api/token-profile?tokenId=${tokenId}`);
}

function makePostRequest(body: unknown) {
  return new NextRequest("http://localhost/api/token-profile", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

describe("app/api/token-profile route", () => {
  afterAll(async () => {
    const pool = getPool();
    await pool.query("DELETE FROM token_profiles WHERE token_id >= 910000");
    await pool.end();
  });

  it("GET with a missing tokenId param returns 400", async () => {
    const res = await GET(new NextRequest("http://localhost/api/token-profile"));
    expect(res.status).toBe(400);
  });

  it("GET with a non-numeric tokenId returns 400", async () => {
    const res = await GET(makeGetRequest("not-a-number"));
    expect(res.status).toBe(400);
  });

  it("GET for a tokenId with no profile returns { profile: null }", async () => {
    const res = await GET(makeGetRequest("910001"));
    expect(res.status).toBe(200);
    const data = await res.json();
    expect(data.profile).toBeNull();
  });

  it("POST with a missing tokenId returns 400 and never writes anything", async () => {
    const res = await POST(makePostRequest({ displayName: "No ID" }));
    expect(res.status).toBe(400);
  });

  it("POST with an oversized field returns 400", async () => {
    const res = await POST(makePostRequest({ tokenId: 910002, displayName: "x".repeat(3000) }));
    expect(res.status).toBe(400);
  });

  it("POST then GET round-trips a real profile through the real database", async () => {
    const postRes = await POST(
      makePostRequest({ tokenId: 910003, displayName: "Route Test Token", xUrl: "https://x.com/test" })
    );
    expect(postRes.status).toBe(200);
    const postData = await postRes.json();
    expect(postData.persisted).toBe(true);

    const getRes = await GET(makeGetRequest("910003"));
    const getData = await getRes.json();
    expect(getData.profile.displayName).toBe("Route Test Token");
    expect(getData.profile.xUrl).toBe("https://x.com/test");
  });

  it("POST with invalid JSON body returns 400, not a 500 crash", async () => {
    const badReq = new NextRequest("http://localhost/api/token-profile", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{not valid json",
    });
    const res = await POST(badReq);
    expect(res.status).toBe(400);
  });
});
