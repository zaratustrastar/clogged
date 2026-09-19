import { NextRequest, NextResponse } from "next/server";
import { lookupTickerForTokenId } from "@/lib/onchain/tickerLookup";
import { PostgresTokenProfileStore } from "@/lib/metadata/PostgresTokenProfileStore";
import { LEGACY_HOOD_DEPLOYMENT, getKnownDeploymentById, type DeploymentIdentity } from "@/lib/web3/deployments";
import { env } from "@/lib/web3/env";

const profileStore = new PostgresTokenProfileStore();

/**
 * NFT metadata endpoint, dispatched strictly by URL segment count - a
 * catch-all route rather than two separate dynamic routes, because Next.js
 * requires every dynamic segment at the same path depth to share one
 * parameter name (confirmed directly: mixing [tokenId] and [deploymentId]
 * at the same depth is a hard `next build` failure, not a lint warning).
 *
 * slug.length === 1 -> /api/ticker-metadata/<tokenId> - the LEGACY route.
 * Permanently bound to LEGACY_HOOD_DEPLOYMENT (a fixed constant), NEVER
 * the app's active deployment config: this exact URL is baked into
 * already-minted HOOD TickerNFTs' immutable on-chain base URI, and once
 * clog.run's active env is switched to point at the canary (or any future
 * deployment), the dynamic env config will no longer refer to HOOD at all
 * - this route must keep resolving HOOD regardless.
 *
 * slug.length === 2 -> /api/ticker-metadata/<deploymentId>/<tokenId> - the
 * deployment-scoped route for every deployment OTHER than legacy HOOD.
 * deploymentId is resolved ONLY through the fixed server-side table in
 * lib/web3/deployments.ts (getKnownDeploymentById) - never accepted as a
 * raw chain id/registry address pair from the client, and an unrecognized
 * deploymentId returns 404 rather than falling back to any default.
 *
 * Any other slug length is an explicit 400, never silently routed as if
 * it were one of the two supported shapes.
 */
export async function GET(request: NextRequest, { params }: { params: { slug: string[] } }) {
  const slug = params.slug ?? [];

  let deployment: DeploymentIdentity;
  let tokenIdRaw: string;
  let imageBasePath: string;

  if (slug.length === 1) {
    deployment = LEGACY_HOOD_DEPLOYMENT;
    tokenIdRaw = slug[0];
    imageBasePath = "/api/ticker-image";
  } else if (slug.length === 2) {
    const resolved = getKnownDeploymentById(slug[0]);
    if (!resolved) {
      return NextResponse.json({ error: "Unknown deploymentId." }, { status: 404 });
    }
    deployment = resolved;
    tokenIdRaw = slug[1];
    imageBasePath = `/api/ticker-image/${slug[0]}`;
  } else {
    return NextResponse.json({ error: "Expected /api/ticker-metadata/<tokenId> or /api/ticker-metadata/<deploymentId>/<tokenId>." }, { status: 400 });
  }

  const tokenIdNum = Number(tokenIdRaw);
  if (!Number.isInteger(tokenIdNum) || tokenIdNum < 0) {
    return NextResponse.json({ error: "tokenId must be a non-negative integer" }, { status: 400 });
  }

  const result = await lookupTickerForTokenId(tokenIdNum, deployment);

  if (result.status === "not_configured") {
    return NextResponse.json({ error: "Protocol contracts not configured yet." }, { status: 503 });
  }
  if (result.status === "rpc_error") {
    return NextResponse.json({ error: "Failed to read onchain state." }, { status: 502 });
  }
  if (result.status === "not_found") {
    return NextResponse.json({ error: "Token does not exist." }, { status: 404 });
  }

  const ticker = result.ticker;
  const profile = await profileStore.get(tokenIdNum, deployment);
  const isV2 = slug.length === 2 && slug[0] === "v2";

  // TickerNFT artwork is deliberately NEVER the user-uploaded meme image.
  // The NFT represents ownership of the ticker identity itself (closer to
  // ENS than to meme art) - every ticker shares the same recognizable CLOG
  // collection look, generated deterministically, not stored anywhere. The
  // uploaded meme image (profile?.imageUrl, if any) remains fully intact
  // and in use elsewhere in the product (token pages, token cards) - it's
  // simply never referenced as NFT metadata.image.
  const image = `${baseUrl(request)}${imageBasePath}/${tokenIdNum}`;

  // The launch form only ever collects a display name, ticker, image, and
  // socials - there is no separate "description" field to pull from, so one
  // is generated here rather than inventing a field that doesn't exist in
  // the product. The launcher's own display name (if given) is folded into
  // it. V2's own economics (40% of the 0.6% trading tax, i.e. 0.24% of
  // gross trading volume - see BondingCurveClog.sol's TICKER_OWNER_TAX_BPS/
  // BUY_TAX_BPS/SELL_TAX_BPS) are stated specifically and only for the V2
  // deployment: legacy HOOD and canary-v1 run different, already-deployed
  // economics (20% of a 0.5% tax), so applying V2's own numbers to their
  // metadata would be factually wrong for those tokens - they keep the
  // existing, deliberately unspecific wording instead. Neither version ever
  // claims the NFT holder receives the separate 5% ERC-2981 secondary-sale
  // royalty (V2 only) - that belongs to the protocol multisig, not the
  // ticker owner, and is a completely different revenue stream (see
  // TickerNFT.sol's own docs).
  const feeDescription = isV2
    ? `the TickerNFT owner receives 40% of the 0.6% buy/sell trading tax on every $${ticker} trade (0.24% of gross trading volume)`
    : `the TickerNFT owner earns a share of every $${ticker} trade`;
  const description = profile?.displayName
    ? `${profile.displayName} ($${ticker}) — a meme launched on CLOG. Unique inside CLOG; ${feeDescription}.`
    : `$${ticker} — a meme launched on CLOG. Unique inside CLOG; ${feeDescription}.`;

  const attributes: { trait_type: string; value: string | number }[] = [
    { trait_type: "Ticker", value: ticker },
    { trait_type: "Token ID", value: tokenIdNum },
  ];
  if (slug.length === 2) {
    attributes.push({ trait_type: "Deployment", value: slug[0] });
  }

  const metadata = {
    name: `$${ticker} — CLOG Ticker`,
    description,
    image,
    external_url: `https://clog.run/token/${ticker.toLowerCase()}`,
    attributes,
  };

  return NextResponse.json(metadata, {
    headers: {
      // Ownership is deliberately not part of this metadata (see the route's
      // own docs) and the canonical artwork is fully deterministic, so a
      // long, revalidatable cache is appropriate.
      "Cache-Control": "public, max-age=300, stale-while-revalidate=3600",
    },
  });
}

function baseUrl(request: NextRequest): string {
  // Prefer the real production origin when known; fall back to the
  // request's own origin (correct in dev and any environment where
  // NEXT_PUBLIC_APP_URL isn't set).
  return env.appUrl ?? request.nextUrl.origin;
}
