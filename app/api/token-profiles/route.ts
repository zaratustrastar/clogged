import { NextRequest, NextResponse } from "next/server";
import { PostgresTokenProfileStore } from "@/lib/metadata/PostgresTokenProfileStore";
import { MAX_TICKER_COUNT } from "@/lib/constants";

const store = new PostgresTokenProfileStore();

/** Batch counterpart to /api/token-profile - one request enriches a whole
 *  discovered token list (see lib/hooks/useTokenDiscovery.ts) with their
 *  persisted off-chain profiles (imageUrl, displayName, socials) in one
 *  round trip, rather than one request per token. Exactly mirrors the
 *  single-profile route's own deployment resolution: the deployment is
 *  never taken from the client (nothing in the POST body names a
 *  chain/registry) - PostgresTokenProfileStore.getMany falls back to
 *  getActiveDeployment() internally, the app's own server-side config,
 *  the identical mechanism the single-profile route already relies on.
 *
 *  POST with a JSON body, not GET with a query string: the collection can
 *  hold up to MAX_TICKER_COUNT (7,778 - EligibilityRegistry.MAX_TICKERS)
 *  tokens, and a comma-separated query string of that many ids risks
 *  running into URL-length limits various proxies/browsers enforce well
 *  below 7,778 four-to-five-digit numbers - a JSON body has no such
 *  ceiling. Still exactly one HTTP request and one SQL query
 *  (PostgresTokenProfileStore.getMany's own `token_id = ANY($3)`) for the
 *  whole batch, regardless of how large the real collection ever grows to
 *  - the cap below exists only to bound a malformed or abusive request
 *  body, not because a real request would ever need to be split. */
export async function POST(request: NextRequest) {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "invalid JSON body" }, { status: 400 });
  }

  if (typeof body !== "object" || body === null || !("tokenIds" in body) || !Array.isArray((body as { tokenIds: unknown }).tokenIds)) {
    return NextResponse.json({ error: "body must be { tokenIds: number[] }" }, { status: 400 });
  }

  const rawIds = (body as { tokenIds: unknown[] }).tokenIds;
  // The real, contract-enforced upper bound on how many distinct tokenIds
  // could ever legitimately exist (EligibilityRegistry.MAX_TICKERS) - not
  // a guessed or arbitrary round number. A request past this size is
  // necessarily malformed or abusive, never a real, growing collection
  // outgrowing an artificial ceiling the way the previous 500-id cap did.
  if (rawIds.length === 0 || rawIds.length > MAX_TICKER_COUNT) {
    return NextResponse.json({ error: `tokenIds must list between 1 and ${MAX_TICKER_COUNT} ids` }, { status: 400 });
  }

  const tokenIds: number[] = [];
  for (const raw of rawIds) {
    if (typeof raw !== "number" || !Number.isInteger(raw) || raw < 0) {
      return NextResponse.json({ error: "every tokenId must be a non-negative integer" }, { status: 400 });
    }
    tokenIds.push(raw);
  }

  const profiles = await store.getMany(tokenIds);
  return NextResponse.json({ profiles: [...profiles.values()] });
}
