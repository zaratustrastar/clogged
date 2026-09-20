import { NextRequest, NextResponse } from "next/server";
import { PostgresTokenProfileStore } from "@/lib/metadata/PostgresTokenProfileStore";
import { isDatabaseConfigured } from "@/lib/db/pool";
import { isOwnUploadedImageUrl } from "@/lib/storage/filesystem";
import { getActiveDeployment } from "@/lib/web3/deployments";
import { addresses } from "@/lib/web3/addresses";
import { readTickerNftOwner } from "@/lib/onchain/tickerNftOwner";
import { verifySignedProfileUpdate } from "@/lib/metadata/tokenProfileAuth";
import type { TokenProfileUpdate } from "@/lib/metadata/TokenProfileStore";
import type { Hex } from "viem";

const store = new PostgresTokenProfileStore();

export async function GET(request: NextRequest) {
  const tokenIdParam = request.nextUrl.searchParams.get("tokenId");
  const tokenId = tokenIdParam ? Number(tokenIdParam) : NaN;
  if (!Number.isInteger(tokenId) || tokenId < 0) {
    return NextResponse.json({ error: "tokenId must be a non-negative integer" }, { status: 400 });
  }

  const profile = await store.get(tokenId);
  return NextResponse.json({ profile });
}

/**
 * Authorization for a profile write, in order - each step can only ever
 * make a request MORE likely to be rejected, never substitute for a later
 * one:
 *
 * 1. Structural validation (types, string lengths) - unchanged in spirit
 *    from before this authorization existed, just extended to the new
 *    issuedAt/expiresAt/signature fields.
 * 2. imageUrl, if present, must be exactly a URL our own upload system
 *    produced (see lib/storage/filesystem.ts's isOwnUploadedImageUrl) -
 *    checked BEFORE the signature, since it's a cheap, local check with no
 *    reason to wait for it.
 * 3. verifySignedProfileUpdate (lib/metadata/tokenProfileAuth.ts): checks
 *    the signature is fresh (not expired, not artificially long-lived,
 *    not signed in the future) and recovers the real signer from it - pure
 *    cryptography, no network, so a malformed/expired/forged signature is
 *    rejected before any onchain read is even attempted.
 * 4. Only once a signature has verified do we spend an RPC call reading
 *    TickerNFT.ownerOf(tokenId) - the CURRENT owner, read fresh on every
 *    request, never cached or trusted from anywhere else. The recovered
 *    signer (step 3) must equal this exactly. A revert (tokenId was never
 *    actually minted) or RPC failure is treated as "cannot authorize",
 *    never as an implicit allow - the request is rejected the same as a
 *    real ownership mismatch would be.
 *
 * The client-claimed profile fields are never trusted as coming from the
 * ticker's real owner merely because they arrived in this request -
 * ownership is established ONLY by steps 3+4 together, over the EXACT
 * metadata payload being persisted (not merely tokenId+timestamp): the
 * signature is verified against a struct built from these same
 * displayName/imageUrl/xUrl/telegramUrl/websiteUrl values, so a signature
 * produced for one payload can never authorize persisting a different one.
 */
export async function POST(request: NextRequest) {
  if (!isDatabaseConfigured()) {
    // Honest, not a fabricated success - matches TokenProfileStore's own
    // contract (never claim persisted: true when nothing was actually saved).
    return NextResponse.json({ persisted: false, reason: "database not configured" }, { status: 200 });
  }

  let body: Partial<TokenProfileUpdate>;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }

  if (typeof body.tokenId !== "number" || !Number.isInteger(body.tokenId) || body.tokenId < 0) {
    return NextResponse.json({ error: "tokenId must be a non-negative integer" }, { status: 400 });
  }

  // Basic length/type sanity limits - presentation data only, but still
  // worth bounding so a malformed or abusive payload can't write arbitrary
  // amounts of text.
  const MAX_LEN = 2000;
  for (const field of ["displayName", "imageUrl", "xUrl", "telegramUrl", "websiteUrl"] as const) {
    const value = body[field];
    if (value !== undefined && (typeof value !== "string" || value.length > MAX_LEN)) {
      return NextResponse.json({ error: `${field} must be a string under ${MAX_LEN} characters` }, { status: 400 });
    }
  }

  if (typeof body.issuedAt !== "number" || typeof body.expiresAt !== "number" || typeof body.signature !== "string") {
    return NextResponse.json({ error: "issuedAt, expiresAt, and signature are required" }, { status: 400 });
  }
  const signature = body.signature as Hex;

  // Only ever a URL our own upload system actually produced - never an
  // arbitrary external URL, data:, javascript:, or protocol-relative URL,
  // all of which are structurally impossible to match the exact required
  // prefix+filename-shape this checks for (see the function's own docs).
  if (body.imageUrl !== undefined && !isOwnUploadedImageUrl(body.imageUrl)) {
    return NextResponse.json({ error: "imageUrl must be a URL produced by our own upload system" }, { status: 400 });
  }

  const deployment = getActiveDeployment();
  if (!deployment || !addresses.tickerNFT) {
    return NextResponse.json({ error: "protocol not configured" }, { status: 503 });
  }

  const verifyResult = await verifySignedProfileUpdate({
    chainId: deployment.chainId,
    verifyingContract: addresses.tickerNFT,
    profile: {
      tokenId: body.tokenId,
      displayName: body.displayName,
      imageUrl: body.imageUrl,
      xUrl: body.xUrl,
      telegramUrl: body.telegramUrl,
      websiteUrl: body.websiteUrl,
    },
    issuedAt: body.issuedAt,
    expiresAt: body.expiresAt,
    signature,
    now: Math.floor(Date.now() / 1000),
  });
  if (!verifyResult.ok) {
    return NextResponse.json({ error: verifyResult.reason }, { status: 401 });
  }

  const ownerResult = await readTickerNftOwner(body.tokenId, addresses.tickerNFT);
  if (ownerResult.status !== "ok") {
    return NextResponse.json({ error: "could not verify ticker ownership" }, { status: 502 });
  }
  if (verifyResult.signer.toLowerCase() !== ownerResult.owner.toLowerCase()) {
    return NextResponse.json({ error: "signer is not the current owner of this ticker" }, { status: 403 });
  }

  const result = await store.set({
    tokenId: body.tokenId,
    displayName: body.displayName,
    imageUrl: body.imageUrl,
    xUrl: body.xUrl,
    telegramUrl: body.telegramUrl,
    websiteUrl: body.websiteUrl,
  });

  return NextResponse.json(result);
}
