/**
 * TokenProfileStore - the adapter boundary for token metadata (image, X,
 * Telegram, website, and a longer display name) that the CLOG contracts do
 * NOT persist on-chain (confirmed against src/TickerRegistry.sol,
 * src/MemeToken.sol, src/TickerNFT.sol - none of them store this data).
 *
 * This is deliberately NOT wired to Supabase, Firebase, a custom backend, or
 * a new Solidity field yet - that's a real product decision (which
 * persistence layer, who can edit a profile after launch, whether it needs
 * moderation) that shouldn't be made silently by the frontend. See the
 * implementation report for details.
 *
 * What this file gives you now:
 *   - a typed interface any real persistence layer can implement later
 *   - a `NullTokenProfileStore` that is honest about doing nothing (reads
 *     return null, writes resolve without claiming anything was saved)
 *   - the exported `tokenProfileStore` instance the rest of the app uses,
 *     so wiring a real backend later is a one-line swap here, not a
 *     search-and-replace across every component
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

class NullTokenProfileStore implements TokenProfileStore {
  async get(): Promise<TokenProfile | null> {
    return null;
  }

  async set(): Promise<{ persisted: boolean }> {
    // Deliberately reports persisted: false - no persistence provider is
    // configured, and this must never claim to have saved data it didn't.
    return { persisted: false };
  }
}

export const tokenProfileStore: TokenProfileStore = new NullTokenProfileStore();

export const isMetadataPersistenceConfigured = false;
