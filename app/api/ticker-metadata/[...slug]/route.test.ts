import { describe, it, expect, vi, beforeEach, afterAll, afterEach } from "vitest";
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

// The app's ACTIVE deployment config is deliberately its own, separate
// address (0x1111...) from both HOOD's real one and canary-v1's - matching
// the original test file's own values for the migrated assertions below,
// and specifically NOT either fixed deployment's real address, so tests
// that assert "the legacy/scoped route used its OWN fixed identity, not
// the active one" have a genuine third value to distinguish against.
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

const HOOD_REGISTRY_ADDRESS = "0xaf5b710de2eafd2614d2cffb01b953d8c664ea33";

async function loadRouteConfigured() {
  vi.resetModules();
  Object.assign(process.env, CONFIGURED_ENV);
  return import("@/app/api/ticker-metadata/[...slug]/route");
}

function makeRequest(...slugParts: string[]) {
  return new NextRequest(`http://localhost/api/ticker-metadata/${slugParts.join("/")}`);
}

describe("app/api/ticker-metadata/[...slug] route", () => {
  beforeEach(() => {
    readContractMock.mockReset();
  });

  afterAll(async () => {
    const pool = getPool();
    await pool.query("DELETE FROM token_profiles WHERE token_id >= 920000");
    await pool.end();
    for (const key of Object.keys(CONFIGURED_ENV)) delete process.env[key];
  });

  describe("legacy route: slug.length === 1 (/api/ticker-metadata/<tokenId>)", () => {
    it("returns 503 when protocol contracts are not configured", async () => {
      vi.resetModules();
      for (const key of Object.keys(CONFIGURED_ENV)) delete process.env[key];
      const { GET } = await import("@/app/api/ticker-metadata/[...slug]/route");
      const res = await GET(makeRequest("1"), { params: { slug: ["1"] } });
      expect(res.status).toBe(503);
    });

    it("returns 400 for a non-numeric tokenId", async () => {
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("abc"), { params: { slug: ["abc"] } });
      expect(res.status).toBe(400);
    });

    it("returns 404 when tickerOf resolves to an empty string (token never launched)", async () => {
      readContractMock.mockResolvedValueOnce("");
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("999"), { params: { slug: ["999"] } });
      expect(res.status).toBe(404);
    });

    it("returns 502 if the onchain read itself fails, rather than fabricating metadata", async () => {
      readContractMock.mockRejectedValueOnce(new Error("RPC unreachable"));
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("5"), { params: { slug: ["5"] } });
      expect(res.status).toBe(502);
    });

    it("returns correct fallback metadata (name/description/image/external_url/attributes) for a real ticker with no profile", async () => {
      readContractMock.mockResolvedValueOnce("CAT");
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("920001"), { params: { slug: ["920001"] } });
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
      // No deployment attribute on the legacy route.
      expect(data.attributes.some((a: { trait_type: string }) => a.trait_type === "Deployment")).toBe(false);
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
      // Deployment-scoped now: the legacy route resolves against
      // LEGACY_HOOD_DEPLOYMENT, so the profile must be stored under that
      // exact identity for the route to find it - not the active env's
      // deployment (0x1111...), which is a different registry entirely.
      const { LEGACY_HOOD_DEPLOYMENT } = await import("@/lib/web3/deployments");
      await profileStore.set(
        {
          tokenId: 920002,
          displayName: "Cat Coin",
          imageUrl: "https://clog.run/uploads/real-cat-meme.png",
        },
        LEGACY_HOOD_DEPLOYMENT
      );

      readContractMock.mockResolvedValueOnce("CAT");
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("920002"), { params: { slug: ["920002"] } });
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
      const res = await GET(makeRequest("920003"), { params: { slug: ["920003"] } });
      expect(res.headers.get("Cache-Control")).toMatch(/public/);
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

    it("the legacy response is unchanged when the active deployment env points elsewhere", async () => {
      readContractMock.mockResolvedValueOnce("HOOD");
      const { GET: getWithActiveA } = await loadRouteConfigured();
      const resA = await getWithActiveA(makeRequest("1"), { params: { slug: ["1"] } });
      const dataA = await resA.json();

      // Change the active deployment's own registry address entirely and
      // reload the route fresh - the legacy response must be identical,
      // since it never reads the active env's registry address at all.
      vi.resetModules();
      Object.assign(process.env, {
        ...CONFIGURED_ENV,
        NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS: "0x2222222222222222222222222222222222222a",
      });
      readContractMock.mockResolvedValueOnce("HOOD");
      const { GET: getWithActiveB } = await import("@/app/api/ticker-metadata/[...slug]/route");
      const resB = await getWithActiveB(makeRequest("1"), { params: { slug: ["1"] } });
      const dataB = await resB.json();

      expect(dataA).toEqual(dataB);
      const secondCallArgs = readContractMock.mock.calls[1][0];
      expect(secondCallArgs.address.toLowerCase()).toBe(HOOD_REGISTRY_ADDRESS);
    });
  });

  describe("deployment-scoped route: slug.length === 2 (/api/ticker-metadata/<deploymentId>/<tokenId>)", () => {
    it("resolves canary-v1 deployment data with a Deployment attribute", async () => {
      readContractMock.mockResolvedValueOnce("CANCAT");
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("canary-v1", "1"), { params: { slug: ["canary-v1", "1"] } });
      expect(res.status).toBe(200);
      const data = await res.json();
      expect(data.name).toContain("CANCAT");
      expect(data.attributes).toContainEqual({ trait_type: "Deployment", value: "canary-v1" });
      expect(data.image).toBe("https://clog.run/api/ticker-image/canary-v1/1");
    });

    it("canary-v1's description keeps the existing, unspecific fee wording - never V2's specific 40%/0.6%/0.24% numbers, which would misstate canary's own different, already-deployed economics", async () => {
      readContractMock.mockResolvedValueOnce("CANCAT");
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("canary-v1", "1"), { params: { slug: ["canary-v1", "1"] } });
      const data = await res.json();
      expect(data.description).not.toContain("40%");
      expect(data.description).not.toContain("0.24%");
      expect(data.description).toContain("earns a share of every");
    });

    it("the v2 deploymentId's metadata uses V2's own image route and states V2's specific, accurate economics (40% of the 0.6% tax, 0.24% of gross volume) - and never claims the NFT holder receives the separate 5% secondary-sale royalty, which belongs to the multisig instead", async () => {
      readContractMock.mockResolvedValueOnce("NEWDOG");
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeRequest("v2", "1"), { params: { slug: ["v2", "1"] } });
      expect(res.status).toBe(200);
      const data = await res.json();
      expect(data.name).toBe("$NEWDOG — CLOG Ticker");
      expect(data.image).toBe("https://clog.run/api/ticker-image/v2/1");
      expect(data.attributes).toContainEqual({ trait_type: "Deployment", value: "v2" });
      expect(data.description).toContain("40%");
      expect(data.description).toContain("0.6%");
      expect(data.description).toContain("0.24%");
      expect(data.description).not.toContain("5%");
      expect(data.description.toLowerCase()).not.toContain("royalty");
    });

    it("REGRESSION GUARD: canary-v1 metadata stays frozen to its own real registry even when the active env is reconfigured to a different (V2-like) deployment", async () => {
      readContractMock.mockResolvedValueOnce("CANCAT");
      vi.resetModules();
      const postCutoverAddress = "0x9999999999999999999999999999999999999f";
      Object.assign(process.env, CONFIGURED_ENV, { NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS: postCutoverAddress });
      const { GET } = await import("@/app/api/ticker-metadata/[...slug]/route");

      const res = await GET(makeRequest("canary-v1", "1"), { params: { slug: ["canary-v1", "1"] } });
      expect(res.status).toBe(200);

      const calledWith = readContractMock.mock.calls[0][0];
      expect(calledWith.address.toLowerCase()).not.toBe(postCutoverAddress);
      expect(calledWith.address.toLowerCase()).not.toBe(CONFIGURED_ENV.NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS.toLowerCase());
    });

    it("queries canary-v1's own fixed registry address, neither HOOD's nor the active deployment's", async () => {
      readContractMock.mockResolvedValueOnce("CANCAT");
      const { GET } = await loadRouteConfigured();
      await GET(makeRequest("canary-v1", "1"), { params: { slug: ["canary-v1", "1"] } });

      expect(readContractMock).toHaveBeenCalledTimes(1);
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
    it("tokenId=1 under legacy HOOD and tokenId=1 under canary-v1 never resolve to the same query or response", async () => {
      readContractMock.mockResolvedValueOnce("HOOD").mockResolvedValueOnce("CANCAT");
      const { GET } = await loadRouteConfigured();

      const legacyRes = await GET(makeRequest("1"), { params: { slug: ["1"] } });
      const scopedRes = await GET(makeRequest("canary-v1", "1"), { params: { slug: ["canary-v1", "1"] } });

      const legacyData = await legacyRes.json();
      const scopedData = await scopedRes.json();
      expect(legacyData.name).not.toBe(scopedData.name);

      const [firstCallArgs, secondCallArgs] = readContractMock.mock.calls;
      expect(firstCallArgs[0].address.toLowerCase()).not.toBe(secondCallArgs[0].address.toLowerCase());
    });
  });

  describe("invalid slug shapes", () => {
    it("returns 400 for zero slug segments", async () => {
      const { GET } = await loadRouteConfigured();
      const res = await GET(new NextRequest("http://localhost/api/ticker-metadata/"), { params: { slug: [] } });
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
