import { describe, it, expect } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import {
  verifySignedProfileUpdate,
  buildUpdateTokenProfileDomain,
  buildUpdateTokenProfileMessage,
  UPDATE_TOKEN_PROFILE_TYPES,
  MAX_SIGNATURE_LIFETIME_SECONDS,
} from "@/lib/metadata/tokenProfileAuth";

/**
 * Direct tests of verifySignedProfileUpdate itself - no route, no mocking,
 * no database. It has zero I/O (see its own docs), so every scenario here
 * uses REAL EIP-712 signing (a real, hardcoded test private key - not a
 * secret, never used anywhere else) and REAL signature recovery - the same
 * approach app/api/token-profile/route.test.ts uses at the full-route
 * level, but exercising this function's own contract in isolation.
 */

const SIGNER = privateKeyToAccount("0x68ad1b22ccdb494d178882314f0f770b4b1514192f0b6db01f03117faad5dbd7");
const CHAIN_ID = 4663;
const VERIFYING_CONTRACT = "0x9fbe11934c968298e2CaA76F738C8e8f81378b35" as const;

async function sign(
  profile: { tokenId: number; displayName?: string; imageUrl?: string; xUrl?: string; telegramUrl?: string; websiteUrl?: string },
  issuedAt: number,
  expiresAt: number,
  overrides: { chainId?: number; verifyingContract?: `0x${string}` } = {}
) {
  return SIGNER.signTypedData({
    domain: buildUpdateTokenProfileDomain({
      chainId: overrides.chainId ?? CHAIN_ID,
      verifyingContract: overrides.verifyingContract ?? VERIFYING_CONTRACT,
    }),
    types: UPDATE_TOKEN_PROFILE_TYPES,
    primaryType: "UpdateTokenProfile",
    message: buildUpdateTokenProfileMessage({ ...profile, issuedAt, expiresAt }),
  });
}

describe("verifySignedProfileUpdate", () => {
  it("a correctly signed, fresh payload verifies and recovers the real signer", async () => {
    const now = 1_000_000;
    const issuedAt = now;
    const expiresAt = now + 100;
    const profile = { tokenId: 42, displayName: "Real Token" };
    const signature = await sign(profile, issuedAt, expiresAt);

    const result = await verifySignedProfileUpdate({
      chainId: CHAIN_ID,
      verifyingContract: VERIFYING_CONTRACT,
      profile,
      issuedAt,
      expiresAt,
      signature,
      now,
    });

    expect(result.ok).toBe(true);
    if (result.ok) expect(result.signer.toLowerCase()).toBe(SIGNER.address.toLowerCase());
  });

  it("a signature verified at a time before expiresAt but after now-drift still succeeds (freshness boundary is inclusive)", async () => {
    const issuedAt = 1_000_000;
    const expiresAt = issuedAt + 100;
    const profile = { tokenId: 1 };
    const signature = await sign(profile, issuedAt, expiresAt);

    const result = await verifySignedProfileUpdate({
      chainId: CHAIN_ID,
      verifyingContract: VERIFYING_CONTRACT,
      profile,
      issuedAt,
      expiresAt,
      signature,
      now: expiresAt, // exactly at the boundary
    });
    expect(result.ok).toBe(true);
  });

  it("fails once now is past expiresAt", async () => {
    const issuedAt = 1_000_000;
    const expiresAt = issuedAt + 100;
    const profile = { tokenId: 1 };
    const signature = await sign(profile, issuedAt, expiresAt);

    const result = await verifySignedProfileUpdate({
      chainId: CHAIN_ID,
      verifyingContract: VERIFYING_CONTRACT,
      profile,
      issuedAt,
      expiresAt,
      signature,
      now: expiresAt + 1,
    });
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toMatch(/expired/);
  });

  it("fails when expiresAt - issuedAt exceeds MAX_SIGNATURE_LIFETIME_SECONDS, regardless of what now is", async () => {
    const issuedAt = 1_000_000;
    const expiresAt = issuedAt + MAX_SIGNATURE_LIFETIME_SECONDS + 1;
    const profile = { tokenId: 1 };
    const signature = await sign(profile, issuedAt, expiresAt);

    const result = await verifySignedProfileUpdate({
      chainId: CHAIN_ID,
      verifyingContract: VERIFYING_CONTRACT,
      profile,
      issuedAt,
      expiresAt,
      signature,
      now: issuedAt, // fresh by any normal clock, still rejected
    });
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toMatch(/lifetime/);
  });

  it("fails when issuedAt is meaningfully in the future relative to now", async () => {
    const now = 1_000_000;
    const issuedAt = now + 10_000; // way beyond any reasonable clock-skew tolerance
    const expiresAt = issuedAt + 100;
    const profile = { tokenId: 1 };
    const signature = await sign(profile, issuedAt, expiresAt);

    const result = await verifySignedProfileUpdate({
      chainId: CHAIN_ID,
      verifyingContract: VERIFYING_CONTRACT,
      profile,
      issuedAt,
      expiresAt,
      signature,
      now,
    });
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toMatch(/future/);
  });

  it("fails when expiresAt is not after issuedAt", async () => {
    const result = await verifySignedProfileUpdate({
      chainId: CHAIN_ID,
      verifyingContract: VERIFYING_CONTRACT,
      profile: { tokenId: 1 },
      issuedAt: 1000,
      expiresAt: 1000, // equal, not after
      signature: "0x00",
      now: 1000,
    });
    expect(result.ok).toBe(false);
  });

  it("recovers a DIFFERENT (wrong) signer, never throwing, when the verified payload differs from what was actually signed - the caller is responsible for treating this as unauthorized, not this function catching it as an error", async () => {
    const issuedAt = 1_000_000;
    const expiresAt = issuedAt + 100;
    const originalProfile = { tokenId: 42, displayName: "Original" };
    const signature = await sign(originalProfile, issuedAt, expiresAt);

    const tamperedProfile = { tokenId: 42, displayName: "Tampered" };
    const result = await verifySignedProfileUpdate({
      chainId: CHAIN_ID,
      verifyingContract: VERIFYING_CONTRACT,
      profile: tamperedProfile,
      issuedAt,
      expiresAt,
      signature,
      now: issuedAt,
    });

    // Cryptographically, this still "succeeds" (recovers SOME address) -
    // it just isn't SIGNER's. This is exactly why the route layer must
    // separately compare the recovered signer against the real onchain
    // owner - this function's own job stops at "who does this signature,
    // for this exact payload, actually recover to".
    expect(result.ok).toBe(true);
    if (result.ok) expect(result.signer.toLowerCase()).not.toBe(SIGNER.address.toLowerCase());
  });

  it("fails (malformed signature) for a garbage signature string", async () => {
    const result = await verifySignedProfileUpdate({
      chainId: CHAIN_ID,
      verifyingContract: VERIFYING_CONTRACT,
      profile: { tokenId: 1 },
      issuedAt: 1000,
      expiresAt: 1100,
      signature: "0xnotarealsignature",
      now: 1000,
    });
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toMatch(/invalid signature/);
  });
});
