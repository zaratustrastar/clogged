import { NextRequest, NextResponse } from "next/server";
import { lookupTickerForTokenId } from "@/lib/onchain/tickerLookup";
import { generateTickerArtwork } from "@/lib/tickerArtwork";

/**
 * Canonical TickerNFT artwork endpoint - the deterministic CLOG collection
 * image, never the user-uploaded meme image (see lib/tickerArtwork.ts's own
 * docs for why these are deliberately different things). Verifies onchain
 * existence itself (via the same shared lookup ticker-metadata uses) so this
 * route is safe to call independently of the metadata route and never
 * fabricates artwork for a tokenId that was never actually launched.
 */
export async function GET(request: NextRequest, { params }: { params: { tokenId: string } }) {
  const tokenIdNum = Number(params.tokenId);
  if (!Number.isInteger(tokenIdNum) || tokenIdNum < 0) {
    return NextResponse.json({ error: "tokenId must be a non-negative integer" }, { status: 400 });
  }

  const result = await lookupTickerForTokenId(tokenIdNum);

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
