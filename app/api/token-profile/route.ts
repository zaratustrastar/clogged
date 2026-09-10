import { NextRequest, NextResponse } from "next/server";
import { PostgresTokenProfileStore } from "@/lib/metadata/PostgresTokenProfileStore";
import { isDatabaseConfigured } from "@/lib/db/pool";
import type { TokenProfile } from "@/lib/metadata/TokenProfileStore";

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

export async function POST(request: NextRequest) {
  if (!isDatabaseConfigured()) {
    // Honest, not a fabricated success - matches TokenProfileStore's own
    // contract (never claim persisted: true when nothing was actually saved).
    return NextResponse.json({ persisted: false, reason: "database not configured" }, { status: 200 });
  }

  let body: Partial<TokenProfile>;
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
