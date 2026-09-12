import "server-only";
import { getPool, isDatabaseConfigured } from "@/lib/db/pool";
import type { TokenProfile, TokenProfileStore } from "@/lib/metadata/TokenProfileStore";

/**
 * Real, server-only Postgres implementation of TokenProfileStore. Only ever
 * reached from API routes (app/api/token-profile/route.ts,
 * app/api/ticker-metadata/[tokenId]/route.ts) - never imported from client
 * components, which use the fetch-based client in
 * lib/metadata/TokenProfileStore.ts instead.
 *
 * DEPLOYMENT-SCOPED: a bare token_id is only unique WITHIN one specific
 * (chain, TickerRegistry) deployment - see migration 002 for why. This
 * store resolves the active deployment's identity from the server's own
 * env config (never from client input, which could otherwise let a caller
 * spoof which deployment's records they're reading or writing), so
 * NEXT_PUBLIC_ROBINHOOD_CHAIN_ID/NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS at
 * request time is the single source of truth for "which deployment is this
 * server instance currently serving" - exactly the same variables every
 * other part of the app already reads for the identical purpose. Switching
 * clog.run from HOOD to the canary (or back) is a deployment config change
 * only; this class needs no code change either way, and old HOOD rows and
 * new canary rows coexist in the same table without ever colliding or
 * being visible to each other.
 *
 * `set()` is a single idempotent upsert keyed on the full composite key -
 * calling it repeatedly with the same data is always safe, and calling it
 * again with updated fields simply overwrites the previous profile
 * (image/socials are presentation data the launcher may reasonably want to
 * fix after launch; nothing about onchain state depends on this table).
 */
export class PostgresTokenProfileStore implements TokenProfileStore {
  private activeDeployment(): { chainId: number; tickerRegistryAddress: string } | null {
    const chainIdRaw = process.env.NEXT_PUBLIC_ROBINHOOD_CHAIN_ID;
    const tickerRegistryAddress = process.env.NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS;
    if (!chainIdRaw || !tickerRegistryAddress) return null;
    const chainId = Number(chainIdRaw);
    if (!Number.isInteger(chainId)) return null;
    // Addresses are compared byte-for-byte after lowercasing - Postgres TEXT
    // comparison is case-sensitive, and a checksum-cased address written
    // once must still match a differently-cased read of the same env var.
    return { chainId, tickerRegistryAddress: tickerRegistryAddress.toLowerCase() };
  }

  async get(tokenId: number): Promise<TokenProfile | null> {
    if (!isDatabaseConfigured()) return null;
    const deployment = this.activeDeployment();
    if (!deployment) return null;
    const pool = getPool();
    const { rows } = await pool.query(
      `SELECT token_id, display_name, image_url, x_url, telegram_url, website_url
       FROM token_profiles WHERE chain_id = $1 AND ticker_registry_address = $2 AND token_id = $3`,
      [deployment.chainId, deployment.tickerRegistryAddress, tokenId]
    );
    if (rows.length === 0) return null;
    const row = rows[0];
    return {
      tokenId: Number(row.token_id),
      displayName: row.display_name ?? undefined,
      imageUrl: row.image_url ?? undefined,
      xUrl: row.x_url ?? undefined,
      telegramUrl: row.telegram_url ?? undefined,
      websiteUrl: row.website_url ?? undefined,
    };
  }

  async set(profile: TokenProfile): Promise<{ persisted: boolean }> {
    if (!isDatabaseConfigured()) return { persisted: false };
    const deployment = this.activeDeployment();
    // Honest, not a fabricated success - matches this store's own contract
    // (never claim persisted: true when nothing was actually saved). A
    // missing chain id/registry address means the server genuinely cannot
    // determine which deployment this write belongs to.
    if (!deployment) return { persisted: false };
    const pool = getPool();
    await pool.query(
      `INSERT INTO token_profiles
         (chain_id, ticker_registry_address, token_id, display_name, image_url, x_url, telegram_url, website_url, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now())
       ON CONFLICT (chain_id, ticker_registry_address, token_id) DO UPDATE SET
         display_name = EXCLUDED.display_name,
         image_url = EXCLUDED.image_url,
         x_url = EXCLUDED.x_url,
         telegram_url = EXCLUDED.telegram_url,
         website_url = EXCLUDED.website_url,
         updated_at = now()`,
      [
        deployment.chainId,
        deployment.tickerRegistryAddress,
        profile.tokenId,
        profile.displayName ?? null,
        profile.imageUrl ?? null,
        profile.xUrl ?? null,
        profile.telegramUrl ?? null,
        profile.websiteUrl ?? null,
      ]
    );
    return { persisted: true };
  }
}
