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

const HOOD_REGISTRY_ADDRESS = "0xaf5b710de2eafd2614d2cffb01b953d8c664ea33";

async function loadRouteConfigured() {
  vi.resetModules();
  Object.assign(process.env, CONFIGURED_ENV);
  return import("@/app/api/ticker-image/[...slug]/route");
}

function makeRequest(...slugParts: string[]) {
  return new NextRequest(`http://localhost/api/ticker-image/${slugParts.join("/")}`);
}

describe("app/api/ticker-image/[...slug] route", () => {
  beforeEach(() => {
    readContractMock.mockReset();
  });

  describe("legacy route: slug.length === 1 (/api/ticker-image/<tokenId>)", () => {
    it("returns 503 when protocol contracts are not configured", async () => {
      vi.resetModules();
      for (const key of Object.keys(CONFIGURED_ENV)) delete process.env[key];
      const { GET } = await import("@/app/api/ticker-image/[...slug]/route");
      const res = await GET(makeRequest("1"), { params: { slug: ["1"] } });
      expect(res.status).toBe(503);
    });

    it("returns 400 for a non-numeric tokenId", async () => {
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("abc"), { params: { slug: ["abc"] } });
      expect(res.status).toBe(400);
    });

    it("a nonexistent tokenId returns 404, never a legitimate-looking image", async () => {
      readContractMock.mockResolvedValueOnce(""); // tickerOf's zero-value - never launched
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("999999"), { params: { slug: ["999999"] } });
      expect(res.status).toBe(404);
      const body = await res.text();
      expect(body).not.toContain("<svg");
    });

    it("returns 502 if the onchain read fails, rather than fabricating artwork", async () => {
      readContractMock.mockRejectedValueOnce(new Error("RPC unreachable"));
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("5"), { params: { slug: ["5"] } });
      expect(res.status).toBe(502);
    });

    it("a real, existing token returns a valid SVG with the correct content type", async () => {
      readContractMock.mockResolvedValueOnce("CAT");
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("1"), { params: { slug: ["1"] } });
      expect(res.status).toBe(200);
      expect(res.headers.get("Content-Type")).toBe("image/svg+xml");
      const svg = await res.text();
      expect(svg).toContain("<svg");
      expect(svg).toContain("$CAT");
    });

    it("responds with a long, immutable cache header (deterministic per tokenId)", async () => {
      readContractMock.mockResolvedValueOnce("CAT");
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("1"), { params: { slug: ["1"] } });
      expect(res.headers.get("Cache-Control")).toMatch(/immutable/);
    });

    it("the same tokenId served twice through the real route returns byte-identical artwork", async () => {
      readContractMock.mockResolvedValue("DOG");
      const { GET } = await loadRouteConfigured();
      const res1 = await GET(makeRequest("42"), { params: { slug: ["42"] } });
      const res2 = await GET(makeRequest("42"), { params: { slug: ["42"] } });
      expect(await res1.text()).toBe(await res2.text());
    });

    it("queries the fixed HOOD TickerRegistry address, never the active deployment's", async () => {
      readContractMock.mockResolvedValueOnce("HOOD");
      const { GET } = await loadRouteConfigured();
      await GET(makeRequest("1"), { params: { slug: ["1"] } });

      expect(readContractMock).toHaveBeenCalledTimes(1);
      const calledWith = readContractMock.mock.calls[0][0];
      expect(calledWith.address.toLowerCase()).toBe(HOOD_REGISTRY_ADDRESS);
      expect(calledWith.address.toLowerCase()).not.toBe(CONFIGURED_ENV.NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS.toLowerCase());
    });
  });

  describe("deployment-scoped route: slug.length === 2 (/api/ticker-image/<deploymentId>/<tokenId>)", () => {
    it("resolves canary-v1 artwork using canary-v1's own fixed registry address", async () => {
      readContractMock.mockResolvedValueOnce("CANCAT");
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("canary-v1", "1"), { params: { slug: ["canary-v1", "1"] } });
      expect(res.status).toBe(200);
      const svg = await res.text();
      expect(svg).toContain("$CANCAT");

      const calledWith = readContractMock.mock.calls[0][0];
      expect(calledWith.address.toLowerCase()).not.toBe(HOOD_REGISTRY_ADDRESS);
      expect(calledWith.address.toLowerCase()).not.toBe(CONFIGURED_ENV.NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS.toLowerCase());
    });

    it("returns 404 for an unknown deploymentId, never falling back to any default deployment", async () => {
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("not-a-real-deployment", "1"), {
        params: { slug: ["not-a-real-deployment", "1"] },
      });
      expect(res.status).toBe(404);
      expect(readContractMock).not.toHaveBeenCalled();
    });

    it("returns 400 for a malformed tokenId under a known deploymentId", async () => {
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("canary-v1", "abc"), { params: { slug: ["canary-v1", "abc"] } });
      expect(res.status).toBe(400);
    });
  });

  describe("cross-deployment collision safety", () => {
    it("tokenId=1 under legacy HOOD and tokenId=1 under canary-v1 never resolve to the same artwork or query", async () => {
      readContractMock.mockResolvedValueOnce("HOOD").mockResolvedValueOnce("CANCAT");
      const { GET } = await loadRouteConfigured();

      const legacyRes = await GET(makeRequest("1"), { params: { slug: ["1"] } });
      const scopedRes = await GET(makeRequest("canary-v1", "1"), { params: { slug: ["canary-v1", "1"] } });

      expect(await legacyRes.text()).not.toBe(await scopedRes.text());
      const [firstCallArgs, secondCallArgs] = readContractMock.mock.calls;
      expect(firstCallArgs[0].address.toLowerCase()).not.toBe(secondCallArgs[0].address.toLowerCase());
    });
  });

  describe("invalid slug shapes", () => {
    it("returns 400 for zero slug segments", async () => {
      const { GET } = await loadRouteConfigured();
      const res = await GET(new NextRequest("http://localhost/api/ticker-image/"), { params: { slug: [] } });
      expect(res.status).toBe(400);
      expect(readContractMock).not.toHaveBeenCalled();
    });

    it("returns 400 for three or more slug segments", async () => {
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("canary-v1", "1", "extra"), {
        params: { slug: ["canary-v1", "1", "extra"] },
      });
      expect(res.status).toBe(400);
      expect(readContractMock).not.toHaveBeenCalled();
    });
  });
});
