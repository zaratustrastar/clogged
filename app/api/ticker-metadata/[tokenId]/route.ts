import { NextRequest, NextResponse } from "next/server";
import { lookupTickerForTokenId } from "@/lib/onchain/tickerLookup";
import { PostgresTokenProfileStore } from "@/lib/metadata/PostgresTokenProfileStore";
import { env } from "@/lib/web3/env";

const profileStore = new PostgresTokenProfileStore();

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

  const ticker = result.ticker;
  const profile = await profileStore.get(tokenIdNum);

  // TickerNFT artwork is deliberately NEVER the user-uploaded meme image.
  // The NFT represents ownership of the ticker identity itself (closer to
  // ENS than to meme art) - every ticker shares the same recognizable CLOG
  // collection look, generated deterministically, not stored anywhere. The
  // uploaded meme image (profile?.imageUrl, if any) remains fully intact
  // and in use elsewhere in the product (token pages, token cards) - it's
  // simply never referenced as NFT metadata.image.
  const image = `${baseUrl(request)}/api/ticker-image/${tokenIdNum}`;

  // The launch form only ever collects a display name, ticker, image, and
  // socials - there is no separate "description" field to pull from, so one
  // is generated here rather than inventing a field that doesn't exist in
  // the product. The launcher's own display name (if given) is folded into
  // it; the ticker-based name below matches the spec's own example exactly.
  const description = profile?.displayName
    ? `${profile.displayName} ($${ticker}) — a meme launched on CLOG. Unique inside CLOG; the TickerNFT owner earns a share of every $${ticker} trade.`
    : `$${ticker} — a meme launched on CLOG. Unique inside CLOG; the TickerNFT owner earns a share of every $${ticker} trade.`;

  const metadata = {
    name: `$${ticker} — CLOG Ticker`,
    description,
    image,
    external_url: `https://clog.run/token/${ticker.toLowerCase()}`,
    attributes: [
      { trait_type: "Ticker", value: ticker },
      { trait_type: "Token ID", value: tokenIdNum },
    ],
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
