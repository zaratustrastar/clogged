import { NextRequest, NextResponse } from "next/server";
import { lookupTickerForTokenId } from "@/lib/onchain/tickerLookup";
import { generateTickerArtwork } from "@/lib/tickerArtwork";
import { LEGACY_HOOD_DEPLOYMENT, getKnownDeploymentById, type DeploymentIdentity } from "@/lib/web3/deployments";

/**
 * Canonical TickerNFT artwork endpoint - the deterministic CLOG collection
 * image, never the user-uploaded meme image (see lib/tickerArtwork.ts's own
 * docs for why these are deliberately different things).
 *
 * Dispatched strictly by URL segment count, mirroring
 * app/api/ticker-metadata/[...slug]/route.ts exactly (see that file's own
 * docs for why this is a single catch-all route rather than two separate
 * dynamic routes - the same Next.js same-depth-dynamic-segment-name
 * constraint applies here identically):
 *
 * slug.length === 1 -> /api/ticker-image/<tokenId> - the LEGACY route,
 * permanently bound to LEGACY_HOOD_DEPLOYMENT.
 *
 * slug.length === 2 -> /api/ticker-image/<deploymentId>/<tokenId> - the
 * deployment-scoped route, resolved only through the fixed server-side
 * deployment table.
 *
 * Any other slug length is an explicit 400.
 */
export async function GET(request: NextRequest, { params }: { params: { slug: string[] } }) {
  const slug = params.slug ?? [];

  let deployment: DeploymentIdentity;
  let tokenIdRaw: string;

  if (slug.length === 1) {
    deployment = LEGACY_HOOD_DEPLOYMENT;
    tokenIdRaw = slug[0];
  } else if (slug.length === 2) {
    const resolved = getKnownDeploymentById(slug[0]);
    if (!resolved) {
      return NextResponse.json({ error: "Unknown deploymentId." }, { status: 404 });
    }
    deployment = resolved;
    tokenIdRaw = slug[1];
  } else {
    return NextResponse.json({ error: "Expected /api/ticker-image/<tokenId> or /api/ticker-image/<deploymentId>/<tokenId>." }, { status: 400 });
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

  const svg = generateTickerArtwork(result.ticker, tokenIdNum);

  return new NextResponse(svg, {
    headers: {
      "Content-Type": "image/svg+xml",
      // Deterministic: the same tokenId (which can never be reassigned to a
      // different ticker once launched) always produces this exact SVG -
      // safe to cache essentially forever.
      "Cache-Control": "public, max-age=31536000, immutable",
    },
  });
}
