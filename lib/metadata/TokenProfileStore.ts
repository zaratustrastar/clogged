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
