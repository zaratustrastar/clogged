import "server-only";
import { getPool, isDatabaseConfigured } from "@/lib/db/pool";
import { getActiveDeployment, type DeploymentIdentity } from "@/lib/web3/deployments";
import type { TokenProfile, TokenProfileStore } from "@/lib/metadata/TokenProfileStore";

/**
 * Real, server-only Postgres implementation of TokenProfileStore. Only ever
 * reached from API routes (app/api/token-profile/route.ts,
 * app/api/token-profiles/route.ts (the batch counterpart, see getMany below),
 * app/api/ticker-metadata/[...slug]/route.ts,
 * app/api/ticker-metadata/[deploymentId]/[tokenId]/route.ts) - never
 * imported from client components, which use the fetch-based client in
 * lib/metadata/TokenProfileStore.ts instead.
 *
 * DEPLOYMENT-SCOPED: a bare token_id is only unique WITHIN one specific
 * (chain, TickerRegistry) deployment - see migration 002 for why. Every
 * method takes an explicit DeploymentIdentity (never trusting client
 * input for it - see the two metadata routes for how each resolves theirs
 * safely: the legacy route to a hardcoded HOOD constant, the deploymentId
 * route to a fixed server-side table). Falls back to the app's active
 * deployment (getActiveDeployment(), the same dynamic env config every
 * other part of the app already reads) only when no explicit identity is
 * given - this is what the plain token-profile route (used by the
 * launch/trade UI, which always operates on whatever deployment is
 * currently active) relies on, preserving its exact previous behavior.
 *
 * `set()` is a single idempotent upsert keyed on the full composite key -
 * calling it repeatedly with the same data is always safe, and calling it
 * again with updated fields simply overwrites the previous profile
 * (image/socials are presentation data the launcher may reasonably want to
 * fix after launch; nothing about onchain state depends on this table).
 */
export class PostgresTokenProfileStore implements TokenProfileStore {
  async get(tokenId: number, deployment?: DeploymentIdentity): Promise<TokenProfile | null> {
    if (!isDatabaseConfigured()) return null;
    const target = deployment ?? getActiveDeployment();
    if (!target) return null;
    const pool = getPool();
    const { rows } = await pool.query(
      `SELECT token_id, display_name, image_url, x_url, telegram_url, website_url
       FROM token_profiles WHERE chain_id = $1 AND ticker_registry_address = $2 AND token_id = $3`,
      [target.chainId, target.tickerRegistryAddress.toLowerCase(), tokenId]
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

  /** Batch counterpart to get() - one query for a whole set of tokenIds
   *  within a single deployment, so enriching a full discovered token list
   *  (see lib/hooks/useTokenDiscovery.ts) costs one HTTP round trip and one
   *  SQL query total, not one of each per token. `token_id = ANY($3)`
   *  against the table's own composite primary key
   *  (chain_id, ticker_registry_address, token_id - see migration 002)
   *  is answered directly from that index; no new index or migration is
   *  needed for this to be efficient at any realistic token count. */
  async getMany(tokenIds: number[], deployment?: DeploymentIdentity): Promise<Map<number, TokenProfile>> {
    const result = new Map<number, TokenProfile>();
    if (tokenIds.length === 0) return result;
    if (!isDatabaseConfigured()) return result;
    const target = deployment ?? getActiveDeployment();
    if (!target) return result;
    const pool = getPool();
    const { rows } = await pool.query(
      `SELECT token_id, display_name, image_url, x_url, telegram_url, website_url
       FROM token_profiles WHERE chain_id = $1 AND ticker_registry_address = $2 AND token_id = ANY($3)`,
      [target.chainId, target.tickerRegistryAddress.toLowerCase(), tokenIds]
    );
    for (const row of rows) {
      result.set(Number(row.token_id), {
        tokenId: Number(row.token_id),
        displayName: row.display_name ?? undefined,
        imageUrl: row.image_url ?? undefined,
        xUrl: row.x_url ?? undefined,
        telegramUrl: row.telegram_url ?? undefined,
        websiteUrl: row.website_url ?? undefined,
      });
    }
    return result;
  }

  async set(profile: TokenProfile, deployment?: DeploymentIdentity): Promise<{ persisted: boolean }> {
    if (!isDatabaseConfigured()) return { persisted: false };
    const target = deployment ?? getActiveDeployment();
    // Honest, not a fabricated success - matches this store's own contract
    // (never claim persisted: true when nothing was actually saved). A
    // missing/unresolvable deployment identity means the server genuinely
    // cannot determine which deployment this write belongs to.
    if (!target) return { persisted: false };
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
        target.chainId,
        target.tickerRegistryAddress.toLowerCase(),
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
