import { describe, it, expect, vi, beforeEach } from "vitest";
import { NextRequest } from "next/server";

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
  NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS: "0x1111111111111111111111111111111111111a",
  NEXT_PUBLIC_TICKER_NFT_ADDRESS: "0x1111111111111111111111111111111111111b",
  NEXT_PUBLIC_ELIGIBILITY_REGISTRY_ADDRESS: "0x1111111111111111111111111111111111111c",
  NEXT_PUBLIC_ROUND_MANAGER_ADDRESS: "0x1111111111111111111111111111111111111d",
  NEXT_PUBLIC_REWARD_VAULT_ADDRESS: "0x1111111111111111111111111111111111111e",
};

async function loadRouteConfigured() {
  vi.resetModules();
  Object.assign(process.env, CONFIGURED_ENV);
  return import("@/app/api/ticker-image/[tokenId]/route");
}

function makeRequest(tokenId: string) {
  return new NextRequest(`http://localhost/api/ticker-image/${tokenId}`);
}

describe("app/api/ticker-image/[tokenId] route", () => {
  beforeEach(() => {
    readContractMock.mockReset();
  });

  it("returns 503 when protocol contracts are not configured", async () => {
    vi.resetModules();
    for (const key of Object.keys(CONFIGURED_ENV)) delete process.env[key];
    const { GET } = await import("@/app/api/ticker-image/[tokenId]/route");
    const res = await GET(makeRequest("1"), { params: { tokenId: "1" } });
    expect(res.status).toBe(503);
  });

  it("returns 400 for a non-numeric tokenId", async () => {
    const { GET } = await loadRouteConfigured();
    const res = await GET(makeRequest("abc"), { params: { tokenId: "abc" } });
    expect(res.status).toBe(400);
  });

  it("a nonexistent tokenId returns 404, never a legitimate-looking image", async () => {
    readContractMock.mockResolvedValueOnce(""); // tickerOf's zero-value - never launched
    const { GET } = await loadRouteConfigured();
    const res = await GET(makeRequest("999999"), { params: { tokenId: "999999" } });
    expect(res.status).toBe(404);
    const body = await res.text();
    expect(body).not.toContain("<svg");
  });

  it("returns 502 if the onchain read fails, rather than fabricating artwork", async () => {
    readContractMock.mockRejectedValueOnce(new Error("RPC unreachable"));
    const { GET } = await loadRouteConfigured();
    const res = await GET(makeRequest("5"), { params: { tokenId: "5" } });
    expect(res.status).toBe(502);
  });

  it("a real, existing token returns a valid SVG with the correct content type", async () => {
    readContractMock.mockResolvedValueOnce("CAT");
    const { GET } = await loadRouteConfigured();
    const res = await GET(makeRequest("1"), { params: { tokenId: "1" } });
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("image/svg+xml");
    const svg = await res.text();
    expect(svg).toContain("<svg");
    expect(svg).toContain("$CAT");
  });

  it("responds with a long, immutable cache header (deterministic per tokenId)", async () => {
    readContractMock.mockResolvedValueOnce("CAT");
    const { GET } = await loadRouteConfigured();
    const res = await GET(makeRequest("1"), { params: { tokenId: "1" } });
    expect(res.headers.get("Cache-Control")).toMatch(/immutable/);
  });

  it("the same tokenId served twice through the real route returns byte-identical artwork", async () => {
    readContractMock.mockResolvedValue("DOG");
    const { GET } = await loadRouteConfigured();
    const res1 = await GET(makeRequest("42"), { params: { tokenId: "42" } });
    const res2 = await GET(makeRequest("42"), { params: { tokenId: "42" } });
    expect(await res1.text()).toBe(await res2.text());
  });
});
