/**
 * TokenProfileStore - the client-safe adapter boundary for token metadata
 * (image, X, Telegram, website, and a longer display name) that the CLOG
 * contracts do NOT persist on-chain (confirmed against
 * contracts/src/TickerRegistry.sol, MemeToken.sol, TickerNFT.sol - none of
 * them store this data).
 *
 * This file is imported by client components (the launch page) and must
 * never import `pg` or anything server-only - real persistence lives behind
 * app/api/token-profile/route.ts, which uses
 * lib/metadata/PostgresTokenProfileStore.ts server-side. `HttpTokenProfileStore`
 * below just calls that API route over fetch, keeping the exact same
 * interface every caller already uses.
 */

export interface TokenProfile {
  tokenId: number;
  displayName?: string;
  imageUrl?: string;
  xUrl?: string;
  telegramUrl?: string;
  websiteUrl?: string;
}

export interface TokenProfileStore {
  get(tokenId: number): Promise<TokenProfile | null>;
  /** Batch read for enriching a whole discovered token list in one round
   *  trip (see lib/hooks/useTokenDiscovery.ts) rather than one HTTP request
   *  per token. Returns only the profiles that actually exist - tokenIds
   *  with no saved profile are simply absent from the map, never a null
   *  entry, so callers use `.get(tokenId)` and treat a miss as "no
   *  profile" the same way a 0-length tokenIds array or an empty result
   *  set both naturally do. */
  getMany(tokenIds: number[]): Promise<Map<number, TokenProfile>>;
  set(profile: TokenProfile): Promise<{ persisted: boolean }>;
}

class HttpTokenProfileStore implements TokenProfileStore {
  async get(tokenId: number): Promise<TokenProfile | null> {
    try {
      const res = await fetch(`/api/token-profile?tokenId=${tokenId}`);
      if (!res.ok) return null;
      const data = await res.json();
      return data.profile ?? null;
    } catch {
      // Network/server error - a missing profile is never fatal to the
      // surrounding UI, which always has real onchain data to fall back to.
      return null;
    }
  }

  async getMany(tokenIds: number[]): Promise<Map<number, TokenProfile>> {
    if (tokenIds.length === 0) return new Map();
    try {
      const res = await fetch(`/api/token-profiles?tokenIds=${tokenIds.join(",")}`);
      if (!res.ok) return new Map();
      const data = await res.json();
      const profiles: TokenProfile[] = Array.isArray(data.profiles) ? data.profiles : [];
      return new Map(profiles.map((p) => [p.tokenId, p]));
    } catch {
      // Same non-fatal handling as get() above - an enrichment failure
      // just means every token in this batch keeps its onchain-only
      // fallback (imageUrl: null, name: ticker), never a broken page.
      return new Map();
    }
  }

  async set(profile: TokenProfile): Promise<{ persisted: boolean }> {
    try {
      const res = await fetch("/api/token-profile", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(profile),
      });
      if (!res.ok) return { persisted: false };
      const data = await res.json();
      return { persisted: Boolean(data.persisted) };
    } catch {
      return { persisted: false };
    }
  }
}

export const tokenProfileStore: TokenProfileStore = new HttpTokenProfileStore();
