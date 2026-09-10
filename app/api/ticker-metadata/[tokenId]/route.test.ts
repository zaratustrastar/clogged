import { describe, it, expect, vi, beforeEach, afterAll } from "vitest";
import { NextRequest } from "next/server";
import { PostgresTokenProfileStore } from "@/lib/metadata/PostgresTokenProfileStore";
import { getPool } from "@/lib/db/pool";

const readContractMock = vi.fn();
vi.mock("viem", async (importOriginal) => {
  const actual = await importOriginal<typeof import("viem")>();
  return {
    ...actual,
    createPublicClient: vi.fn().mockReturnValue({ readContract: readContractMock }),
  };
});

const CONFIGURED_ENV = {
  NEXT_PUBLIC_ROBINHOOD_CHAIN_ID: "4663",
  NEXT_PUBLIC_ROBINHOOD_RPC_URL: "https://rpc.mainnet.chain.robinhood.com",
  NEXT_PUBLIC_APP_URL: "https://clog.run",
  NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS: "0x1111111111111111111111111111111111111a",
  NEXT_PUBLIC_TICKER_NFT_ADDRESS: "0x1111111111111111111111111111111111111b",
  NEXT_PUBLIC_ELIGIBILITY_REGISTRY_ADDRESS: "0x1111111111111111111111111111111111111c",
  NEXT_PUBLIC_ROUND_MANAGER_ADDRESS: "0x1111111111111111111111111111111111111d",
  NEXT_PUBLIC_REWARD_VAULT_ADDRESS: "0x1111111111111111111111111111111111111e",
};

async function loadRouteConfigured() {
  vi.resetModules();
  Object.assign(process.env, CONFIGURED_ENV);
  return import("@/app/api/ticker-metadata/[tokenId]/route");
}

function makeRequest(tokenId: string) {
  return new NextRequest(`http://localhost/api/ticker-metadata/${tokenId}`);
}

describe("app/api/ticker-metadata/[tokenId] route", () => {
  beforeEach(() => {
    readContractMock.mockReset();
  });

  afterAll(async () => {
    const pool = getPool();
    await pool.query("DELETE FROM token_profiles WHERE token_id >= 920000");
    await pool.end();
    for (const key of Object.keys(CONFIGURED_ENV)) delete process.env[key];
  });

  it("returns 503 when protocol contracts are not configured", async () => {
    vi.resetModules();
    for (const key of Object.keys(CONFIGURED_ENV)) delete process.env[key];
    const { GET } = await import("@/app/api/ticker-metadata/[tokenId]/route");
    const res = await GET(makeRequest("1"), { params: { tokenId: "1" } });
    expect(res.status).toBe(503);
  });

  it("returns 400 for a non-numeric tokenId", async () => {
    const { GET } = await loadRouteConfigured();
    const res = await GET(makeRequest("abc"), { params: { tokenId: "abc" } });
    expect(res.status).toBe(400);
  });

  it("returns 404 when tickerOf resolves to an empty string (token never launched)", async () => {
    readContractMock.mockResolvedValueOnce("");
    const { GET } = await loadRouteConfigured();
    const res = await GET(makeRequest("999"), { params: { tokenId: "999" } });
    expect(res.status).toBe(404);
  });

  it("returns 502 if the onchain read itself fails, rather than fabricating metadata", async () => {
    readContractMock.mockRejectedValueOnce(new Error("RPC unreachable"));
    const { GET } = await loadRouteConfigured();
    const res = await GET(makeRequest("5"), { params: { tokenId: "5" } });
    expect(res.status).toBe(502);
  });

  it("returns correct fallback metadata (name/description/image/external_url/attributes) for a real ticker with no profile", async () => {
    readContractMock.mockResolvedValueOnce("CAT");
    const { GET } = await loadRouteConfigured();
    const res = await GET(makeRequest("920001"), { params: { tokenId: "920001" } });
    expect(res.status).toBe(200);
    const data = await res.json();

    expect(data.name).toBe("$CAT — CLOG Ticker");
    expect(data.external_url).toBe("https://clog.run/token/cat");
    expect(data.attributes).toEqual(
      expect.arrayContaining([
        { trait_type: "Ticker", value: "CAT" },
        { trait_type: "Token ID", value: 920001 },
      ])
    );
    // No custom image was ever set -> the canonical generated TickerNFT
    // artwork route, keyed by tokenId (never the meme-fallback-by-ticker
    // scheme this replaced).
    expect(data.image).toBe("https://clog.run/api/ticker-image/920001");
    // Ownership must never appear as a field in this metadata (an "owner"
    // mentioned in descriptive prose about protocol mechanics is fine and
    // expected - what must never appear is an actual owner address/field
    // reflecting current, changeable ownership state).
    expect(data).not.toHaveProperty("owner");
    expect(data.attributes.some((a: { trait_type: string }) => a.trait_type === "Owner")).toBe(false);
  });

  it("uses canonical generated artwork even when a profile has an uploaded meme image, but still uses the profile's displayName in the description", async () => {
    const profileStore = new PostgresTokenProfileStore();
    await profileStore.set({
      tokenId: 920002,
      displayName: "Cat Coin",
      imageUrl: "https://clog.run/uploads/real-cat-meme.png",
    });

    readContractMock.mockResolvedValueOnce("CAT");
    const { GET } = await loadRouteConfigured();
    const res = await GET(makeRequest("920002"), { params: { tokenId: "920002" } });
    const data = await res.json();

    // TickerNFT artwork is never the uploaded meme image - it represents
    // ticker ownership, not the meme itself (see lib/tickerArtwork.ts).
    // The uploaded image is retained and used elsewhere in the product,
    // just never as NFT metadata.image.
    expect(data.image).toBe("https://clog.run/api/ticker-image/920002");
    expect(data.image).not.toContain("uploads");
    expect(data.description).toContain("Cat Coin");
  });

  it("responds with a Cache-Control header, not an uncached/private response", async () => {
    readContractMock.mockResolvedValueOnce("DOG");
    const { GET } = await loadRouteConfigured();
    const res = await GET(makeRequest("920003"), { params: { tokenId: "920003" } });
    expect(res.headers.get("Cache-Control")).toMatch(/public/);
  });
});
