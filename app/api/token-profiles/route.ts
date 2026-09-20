import { NextRequest, NextResponse } from "next/server";
import { PostgresTokenProfileStore } from "@/lib/metadata/PostgresTokenProfileStore";

const store = new PostgresTokenProfileStore();

/** Batch counterpart to /api/token-profile - one request enriches a whole
 *  discovered token list (see lib/hooks/useTokenDiscovery.ts) with their
 *  persisted off-chain profiles (imageUrl, displayName, socials) in one
 *  round trip, rather than one request per token. Exactly mirrors the
 *  single-profile route's own deployment resolution: the deployment is
 *  never taken from the client (no chain/registry query param exists to
 *  supply one) - PostgresTokenProfileStore.getMany falls back to
 *  getActiveDeployment() internally, the app's own server-side config,
 *  the identical mechanism the single-profile route already relies on. */
export async function GET(request: NextRequest) {
  const tokenIdsParam = request.nextUrl.searchParams.get("tokenIds");
  if (!tokenIdsParam) {
    return NextResponse.json({ error: "tokenIds is required (comma-separated non-negative integers)" }, { status: 400 });
  }

  const parts = tokenIdsParam.split(",").filter((p) => p.length > 0);
  // A generous cap, not a realistic ceiling on today's collection size -
  // just a bound against a malformed or abusive query string, the same
  // spirit as the POST handler's own MAX_LEN string-length cap next door.
  const MAX_TOKEN_IDS = 500;
  if (parts.length === 0 || parts.length > MAX_TOKEN_IDS) {
    return NextResponse.json({ error: `tokenIds must list between 1 and ${MAX_TOKEN_IDS} ids` }, { status: 400 });
  }

  const tokenIds: number[] = [];
  for (const part of parts) {
    const id = Number(part);
    if (!Number.isInteger(id) || id < 0) {
      return NextResponse.json({ error: "every tokenId must be a non-negative integer" }, { status: 400 });
    }
    tokenIds.push(id);
  }

  const profiles = await store.getMany(tokenIds);
  return NextResponse.json({ profiles: [...profiles.values()] });
}
