import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { NextRequest } from "next/server";
import { privateKeyToAccount } from "viem/accounts";
import type { Hex } from "viem";
import deploymentManifest from "@/deployments/robinhood-mainnet.json";
import {
  buildUpdateTokenProfileDomain,
  buildUpdateTokenProfileMessage,
  UPDATE_TOKEN_PROFILE_TYPES,
  MAX_SIGNATURE_LIFETIME_SECONDS,
} from "@/lib/metadata/tokenProfileAuth";

const { readContractMock, storeSetMock, storeGetMock } = vi.hoisted(() => ({
  readContractMock: vi.fn(),
  storeSetMock: vi.fn(),
  storeGetMock: vi.fn(),
}));

vi.mock("viem", async (importOriginal) => {
  const actual = await importOriginal<typeof import("viem")>();
  return {
    ...actual,
    createPublicClient: vi.fn().mockReturnValue({ readContract: readContractMock }),
  };
});

vi.mock("@/lib/metadata/PostgresTokenProfileStore", () => ({
  PostgresTokenProfileStore: class {
    get = storeGetMock;
    set = storeSetMock;
  },
}));

// Deliberately fixed test private keys - not real secrets, generated once
// via viem's own generatePrivateKey() and hardcoded here for deterministic,
// reproducible tests, never used anywhere but this test file. OWNER is who
// the mocked TickerNFT.ownerOf will return by default; ATTACKER is a
// completely different address used for the "signed by someone who is not
// the owner" case.
const OWNER = privateKeyToAccount("0x68ad1b22ccdb494d178882314f0f770b4b1514192f0b6db01f03117faad5dbd7");
const ATTACKER = privateKeyToAccount("0xf5841c844c84b7e82a3ca932f60fa3285f7a3d643a53f893807681d52400b42a");

const CONFIGURED_ENV = {
  DATABASE_URL: "postgres://fake-for-tests-only",
  NEXT_PUBLIC_ROBINHOOD_RPC_URL: "https://rpc.mainnet.chain.robinhood.com",
  NEXT_PUBLIC_APP_URL: "https://clog.run",
  UPLOAD_PUBLIC_BASE_URL: "https://clog.run/uploads",
};
// chainId and every contract address (including TickerNFT) come
// unconditionally from the tracked deployment manifest, never from any
// NEXT_PUBLIC_* env var - see lib/web3/env.ts's own header comment for
// why (a stale env var must never silently override which deployment the
// app reads from). Read the SAME manifest env.ts itself imports, rather
// than hardcoding a possibly-stale duplicate of these two values, so this
// test can never drift from what addresses.tickerNFT/env.chainId will
// really resolve to.
const CHAIN_ID = deploymentManifest.chainId;
const TICKER_NFT_ADDRESS = deploymentManifest.contracts.tickerNFT as Hex;

const VALID_UPLOAD_URL = "https://clog.run/uploads/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png";

async function loadRouteConfigured() {
  vi.resetModules();
  Object.assign(process.env, CONFIGURED_ENV);
  return import("@/app/api/token-profile/route");
}

interface ProfileFields {
  tokenId: number;
  displayName?: string;
  imageUrl?: string;
  xUrl?: string;
  telegramUrl?: string;
  websiteUrl?: string;
}

async function signProfileUpdate(
  account: typeof OWNER,
  profile: ProfileFields,
  overrides: { chainId?: number; verifyingContract?: Hex; issuedAt?: number; expiresAt?: number } = {}
) {
  const issuedAt = overrides.issuedAt ?? Math.floor(Date.now() / 1000);
  const expiresAt = overrides.expiresAt ?? issuedAt + MAX_SIGNATURE_LIFETIME_SECONDS;
  const chainId = overrides.chainId ?? CHAIN_ID;
  const verifyingContract = overrides.verifyingContract ?? TICKER_NFT_ADDRESS;

  const signature = await account.signTypedData({
    domain: buildUpdateTokenProfileDomain({ chainId, verifyingContract }),
    types: UPDATE_TOKEN_PROFILE_TYPES,
    primaryType: "UpdateTokenProfile",
    message: buildUpdateTokenProfileMessage({ ...profile, issuedAt, expiresAt }),
  });

  return { ...profile, issuedAt, expiresAt, signature };
}

function makePostRequest(body: unknown) {
  return new NextRequest("http://localhost/api/token-profile", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function makeGetRequest(tokenId: string) {
  return new NextRequest(`http://localhost/api/token-profile?tokenId=${tokenId}`);
}

describe("app/api/token-profile route", () => {
  beforeEach(() => {
    readContractMock.mockReset();
    storeSetMock.mockReset();
    storeGetMock.mockReset();
    readContractMock.mockResolvedValue(OWNER.address); // TickerNFT.ownerOf defaults to OWNER
    storeSetMock.mockResolvedValue({ persisted: true });
    storeGetMock.mockResolvedValue(null);
  });

  afterEach(() => {
    for (const key of Object.keys(CONFIGURED_ENV)) delete process.env[key];
  });

  describe("GET (unauthenticated read - unaffected by this change)", () => {
    it("with a missing tokenId param returns 400", async () => {
      const { GET } = await loadRouteConfigured();
      const res = await GET(new NextRequest("http://localhost/api/token-profile"));
      expect(res.status).toBe(400);
    });

    it("with a non-numeric tokenId returns 400", async () => {
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeGetRequest("not-a-number"));
      expect(res.status).toBe(400);
    });

    it("for a tokenId with no profile returns { profile: null }", async () => {
      const { GET } = await loadRouteConfigured();
      const res = await GET(makeGetRequest("42"));
      expect(res.status).toBe(200);
      const data = await res.json();
      expect(data.profile).toBeNull();
    });
  });

  describe("POST structural validation (before any signature/ownership check)", () => {
    it("missing tokenId returns 400", async () => {
      const { POST } = await loadRouteConfigured();
      const res = await POST(makePostRequest({ displayName: "No ID" }));
      expect(res.status).toBe(400);
      expect(storeSetMock).not.toHaveBeenCalled();
    });

    it("an oversized field returns 400", async () => {
      const { POST } = await loadRouteConfigured();
      const signed = await signProfileUpdate(OWNER, { tokenId: 42, displayName: "x".repeat(3000) });
      const res = await POST(makePostRequest(signed));
      expect(res.status).toBe(400);
    });

    it("invalid JSON body returns 400, not a 500 crash", async () => {
      const { POST } = await loadRouteConfigured();
      const badReq = new NextRequest("http://localhost/api/token-profile", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{not valid json",
      });
      const res = await POST(badReq);
      expect(res.status).toBe(400);
    });

    it("missing issuedAt/expiresAt/signature returns 400 - a bare profile payload with no authorization is never accepted", async () => {
      const { POST } = await loadRouteConfigured();
      const res = await POST(makePostRequest({ tokenId: 42, displayName: "No auth fields" }));
      expect(res.status).toBe(400);
      expect(storeSetMock).not.toHaveBeenCalled();
    });
  });

  describe("authorization", () => {
    it("correct owner + correctly signed exact payload succeeds", async () => {
      const { POST } = await loadRouteConfigured();
      const signed = await signProfileUpdate(OWNER, {
        tokenId: 42,
        displayName: "Real Owner Token",
        imageUrl: VALID_UPLOAD_URL,
        xUrl: "https://x.com/real",
      });
      const res = await POST(makePostRequest(signed));
      expect(res.status).toBe(200);
      const data = await res.json();
      expect(data.persisted).toBe(true);
      expect(storeSetMock).toHaveBeenCalledWith(
        expect.objectContaining({ tokenId: 42, displayName: "Real Owner Token", imageUrl: VALID_UPLOAD_URL, xUrl: "https://x.com/real" })
      );
    });

    it("no-image profile still succeeds - imageUrl is optional, not required for authorization", async () => {
      const { POST } = await loadRouteConfigured();
      const signed = await signProfileUpdate(OWNER, { tokenId: 42, displayName: "No image here" });
      const res = await POST(makePostRequest(signed));
      expect(res.status).toBe(200);
      const data = await res.json();
      expect(data.persisted).toBe(true);
    });

    it("a correctly-signed payload from someone who is NOT the current owner fails", async () => {
      const { POST } = await loadRouteConfigured();
      // ATTACKER signs a perfectly well-formed request - the signature
      // itself is completely valid, it just isn't the current owner's.
      const signed = await signProfileUpdate(ATTACKER, { tokenId: 42, displayName: "Hijacked" });
      const res = await POST(makePostRequest(signed));
      expect(res.status).toBe(403);
      expect(storeSetMock).not.toHaveBeenCalled();
    });

    it("metadata modified after signing fails - the signature no longer matches the payload actually being persisted", async () => {
      const { POST } = await loadRouteConfigured();
      const signed = await signProfileUpdate(OWNER, { tokenId: 42, displayName: "Original Name" });
      // Tamper with the payload after signing, before sending - exactly
      // what a compromised client-side step, or a request forged by
      // someone who intercepted an old signature, would attempt. ECDSA
      // recovery never "throws" for a mismatched message - it always
      // recovers SOME address, just not OWNER's, for a message that
      // differs from what was actually signed. That wrong recovered
      // address then fails the ownership check (403) - cryptographically
      // indistinguishable, from the server's own point of view, from a
      // signature genuinely produced by some other, non-owner address;
      // either way, the one thing that must hold is storeSetMock is never
      // reached.
      const tampered = { ...signed, displayName: "Tampered Name" };
      const res = await POST(makePostRequest(tampered));
      expect(res.status).toBe(403);
      expect(storeSetMock).not.toHaveBeenCalled();
    });

    it("a signature for a different tokenId fails - it does not carry over to whichever tokenId happens to be in the request body", async () => {
      const { POST } = await loadRouteConfigured();
      const signed = await signProfileUpdate(OWNER, { tokenId: 42, displayName: "For token 42" });
      // Same reasoning as the tampered-metadata case above: recovery
      // succeeds but to the wrong address for this different tokenId, so
      // the ownership check is what actually rejects it (403).
      const wrongTokenId = { ...signed, tokenId: 43 };
      const res = await POST(makePostRequest(wrongTokenId));
      expect(res.status).toBe(403);
      expect(storeSetMock).not.toHaveBeenCalled();
    });

    it("an expired signature fails", async () => {
      const { POST } = await loadRouteConfigured();
      const now = Math.floor(Date.now() / 1000);
      const signed = await signProfileUpdate(OWNER, { tokenId: 42, displayName: "Stale" }, { issuedAt: now - 1000, expiresAt: now - 400 });
      const res = await POST(makePostRequest(signed));
      expect(res.status).toBe(401);
      expect(storeSetMock).not.toHaveBeenCalled();
    });

    it("a signature claiming a lifetime longer than MAX_SIGNATURE_LIFETIME_SECONDS fails, even though it isn't expired yet", async () => {
      const { POST } = await loadRouteConfigured();
      const now = Math.floor(Date.now() / 1000);
      const signed = await signProfileUpdate(OWNER, { tokenId: 42 }, { issuedAt: now, expiresAt: now + MAX_SIGNATURE_LIFETIME_SECONDS + 1000 });
      const res = await POST(makePostRequest(signed));
      expect(res.status).toBe(401);
      expect(storeSetMock).not.toHaveBeenCalled();
    });

    it("a signature produced for the wrong chainId fails - it was never valid for this deployment's own domain", async () => {
      const { POST } = await loadRouteConfigured();
      // Same reasoning as the tampered-metadata case above: the domain is
      // part of what's hashed and signed, so a signature produced for a
      // different chainId recovers to the wrong address here too (403),
      // never a thrown/malformed-signature error (401).
      const signed = await signProfileUpdate(OWNER, { tokenId: 42, displayName: "Wrong chain" }, { chainId: 1 }); // Ethereum mainnet, not Robinhood Chain
      const res = await POST(makePostRequest(signed));
      expect(res.status).toBe(403);
      expect(storeSetMock).not.toHaveBeenCalled();
    });

    it("a signature produced for the wrong TickerNFT/deployment (verifyingContract) fails", async () => {
      const { POST } = await loadRouteConfigured();
      const signed = await signProfileUpdate(
        OWNER,
        { tokenId: 42, displayName: "Wrong deployment" },
        { verifyingContract: "0x9999999999999999999999999999999999999999" }
      );
      const res = await POST(makePostRequest(signed));
      expect(res.status).toBe(403);
      expect(storeSetMock).not.toHaveBeenCalled();
    });

    it("an arbitrary external image URL fails, even with an otherwise perfectly valid signature", async () => {
      const { POST } = await loadRouteConfigured();
      const signed = await signProfileUpdate(OWNER, { tokenId: 42, imageUrl: "https://evil.example.com/tracker.png" });
      const res = await POST(makePostRequest(signed));
      expect(res.status).toBe(400);
      expect(storeSetMock).not.toHaveBeenCalled();
    });

    it("a data: URI as imageUrl fails", async () => {
      const { POST } = await loadRouteConfigured();
      const signed = await signProfileUpdate(OWNER, { tokenId: 42, imageUrl: "data:image/png;base64,aGVsbG8=" });
      const res = await POST(makePostRequest(signed));
      expect(res.status).toBe(400);
    });

    it("a protocol-relative imageUrl fails", async () => {
      const { POST } = await loadRouteConfigured();
      const signed = await signProfileUpdate(OWNER, { tokenId: 42, imageUrl: "//clog.run/uploads/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png" });
      const res = await POST(makePostRequest(signed));
      expect(res.status).toBe(400);
    });

    it("a valid CLOG upload URL succeeds", async () => {
      const { POST } = await loadRouteConfigured();
      const signed = await signProfileUpdate(OWNER, { tokenId: 42, imageUrl: VALID_UPLOAD_URL });
      const res = await POST(makePostRequest(signed));
      expect(res.status).toBe(200);
      const data = await res.json();
      expect(data.persisted).toBe(true);
    });

    it("ownerOf reverting (tokenId never minted) is treated as authorization denied, never as an implicit allow", async () => {
      readContractMock.mockRejectedValueOnce(new Error("execution reverted"));
      const { POST } = await loadRouteConfigured();
      const signed = await signProfileUpdate(OWNER, { tokenId: 999999 });
      const res = await POST(makePostRequest(signed));
      expect(res.status).toBe(502);
      expect(storeSetMock).not.toHaveBeenCalled();
    });
  });
});
