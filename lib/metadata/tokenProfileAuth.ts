import { recoverTypedDataAddress, type Address, type Hex } from "viem";

/**
 * EIP-712 typed-data authorization for POST /api/token-profile writes.
 *
 * Isomorphic (no "server-only", no "use client", no DOM/Node-specific API):
 * imported by app/launch/page.tsx (builds + signs this exact structure with
 * the connected wallet) and app/api/token-profile/route.ts (rebuilds the
 * identical structure server-side from the claimed payload and verifies the
 * signature against it) - both sides must construct the byte-identical
 * message or the signature simply won't recover to the right address,
 * which is the whole point: a signature is only valid for the EXACT
 * metadata payload it was produced over, never merely tokenId+timestamp.
 *
 * The domain's own `verifyingContract` (the deployment's real TickerNFT
 * address) and `chainId` bind the signature to "this exact deployment,
 * this exact chain" - a signature produced for one deployment's TickerNFT
 * can never be replayed against a different one, even one that reuses the
 * same tokenId numbering. The primaryType name itself, "UpdateTokenProfile",
 * is the action binding: EIP-712 hashes the type name into the struct hash,
 * so this signature can never be reinterpreted as authorizing some other
 * action even if a future feature reused any of the same field names.
 */

export const TOKEN_PROFILE_DOMAIN_NAME = "CLOG";
export const TOKEN_PROFILE_DOMAIN_VERSION = "1";

/** How long a signature may remain valid for, at most - enforced server-side
 *  regardless of whatever `expiresAt` a client claims, so a compromised or
 *  buggy client can never mint an unreasonably long-lived, replayable
 *  authorization. The client is still free to request a SHORTER window
 *  (a smaller expiresAt - issuedAt); only a longer one is rejected. */
export const MAX_SIGNATURE_LIFETIME_SECONDS = 300; // 5 minutes

/** Small tolerance for `issuedAt` being slightly ahead of the server's own
 *  clock - real minor client/server clock skew, not a loophole: it only
 *  affects how far in the future issuedAt may claim to be, never expiresAt
 *  or the lifetime cap above. */
const CLOCK_SKEW_TOLERANCE_SECONDS = 60;

export const UPDATE_TOKEN_PROFILE_TYPES = {
  UpdateTokenProfile: [
    { name: "tokenId", type: "uint256" },
    { name: "displayName", type: "string" },
    { name: "imageUrl", type: "string" },
    { name: "xUrl", type: "string" },
    { name: "telegramUrl", type: "string" },
    { name: "websiteUrl", type: "string" },
    { name: "issuedAt", type: "uint256" },
    { name: "expiresAt", type: "uint256" },
  ],
} as const;

export interface TokenProfileFields {
  tokenId: number;
  displayName?: string;
  imageUrl?: string;
  xUrl?: string;
  telegramUrl?: string;
  websiteUrl?: string;
}

export function buildUpdateTokenProfileDomain(params: { chainId: number; verifyingContract: Address }) {
  return {
    name: TOKEN_PROFILE_DOMAIN_NAME,
    version: TOKEN_PROFILE_DOMAIN_VERSION,
    chainId: params.chainId,
    verifyingContract: params.verifyingContract,
  };
}

/** EIP-712 struct fields have no concept of an absent/optional value - every
 *  declared field must carry a concrete value of its declared type. Every
 *  optional string field is normalized to "" when absent, on BOTH the
 *  signing side and the verifying side, so the two can only ever agree when
 *  they mean the exact same thing by "no value" - never "" on one side and
 *  undefined on the other silently producing two different struct hashes
 *  and a signature that only coincidentally happens to verify. */
export function buildUpdateTokenProfileMessage(params: TokenProfileFields & { issuedAt: number; expiresAt: number }) {
  return {
    tokenId: BigInt(params.tokenId),
    displayName: params.displayName ?? "",
    imageUrl: params.imageUrl ?? "",
    xUrl: params.xUrl ?? "",
    telegramUrl: params.telegramUrl ?? "",
    websiteUrl: params.websiteUrl ?? "",
    issuedAt: BigInt(params.issuedAt),
    expiresAt: BigInt(params.expiresAt),
  };
}

export type VerifySignedProfileUpdateResult = { ok: true; signer: Address } | { ok: false; reason: string };

/**
 * Pure verification: given a claimed metadata payload, an issuedAt/expiresAt
 * window, and a signature, checks freshness and recovers the real signer -
 * no I/O, no network, no database. Deliberately does NOT check ownership:
 * that requires an onchain TickerNFT.ownerOf(tokenId) read, which belongs
 * to the caller (see app/api/token-profile/route.ts), keeping this function
 * fully offline and directly testable with real cryptographic signatures,
 * no mocking required.
 *
 * `now` is an explicit parameter, never read internally via Date.now() -
 * callers (and tests) control it directly, so freshness/expiry behavior is
 * deterministic rather than racing the real clock.
 */
export async function verifySignedProfileUpdate(params: {
  chainId: number;
  verifyingContract: Address;
  profile: TokenProfileFields;
  issuedAt: number;
  expiresAt: number;
  signature: Hex;
  now: number;
}): Promise<VerifySignedProfileUpdateResult> {
  const { chainId, verifyingContract, profile, issuedAt, expiresAt, signature, now } = params;

  if (!Number.isInteger(issuedAt) || !Number.isInteger(expiresAt)) {
    return { ok: false, reason: "issuedAt and expiresAt must be integers" };
  }
  if (expiresAt <= issuedAt) {
    return { ok: false, reason: "expiresAt must be after issuedAt" };
  }
  if (expiresAt - issuedAt > MAX_SIGNATURE_LIFETIME_SECONDS) {
    return { ok: false, reason: `signature lifetime exceeds the maximum allowed (${MAX_SIGNATURE_LIFETIME_SECONDS}s)` };
  }
  if (issuedAt > now + CLOCK_SKEW_TOLERANCE_SECONDS) {
    return { ok: false, reason: "issuedAt is in the future" };
  }
  if (now > expiresAt) {
    return { ok: false, reason: "signature has expired" };
  }

  let signer: Address;
  try {
    signer = await recoverTypedDataAddress({
      domain: buildUpdateTokenProfileDomain({ chainId, verifyingContract }),
      types: UPDATE_TOKEN_PROFILE_TYPES,
      primaryType: "UpdateTokenProfile",
      message: buildUpdateTokenProfileMessage({ ...profile, issuedAt, expiresAt }),
      signature,
    });
  } catch {
    return { ok: false, reason: "invalid signature" };
  }

  return { ok: true, signer };
}
