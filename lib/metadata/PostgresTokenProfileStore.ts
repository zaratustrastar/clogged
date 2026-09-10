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
 * `set()` is a single idempotent upsert keyed on token_id - calling it
 * repeatedly with the same data is always safe, and calling it again with
 * updated fields simply overwrites the previous profile (image/socials are
 * presentation data the launcher may reasonably want to fix after launch;
 * nothing about onchain state depends on this table).
 */
export class PostgresTokenProfileStore implements TokenProfileStore {
  async get(tokenId: number): Promise<TokenProfile | null> {
    if (!isDatabaseConfigured()) return null;
    const pool = getPool();
    const { rows } = await pool.query(
      `SELECT token_id, display_name, image_url, x_url, telegram_url, website_url
       FROM token_profiles WHERE token_id = $1`,
      [tokenId]
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
    const pool = getPool();
    await pool.query(
      `INSERT INTO token_profiles (token_id, display_name, image_url, x_url, telegram_url, website_url, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6, now())
       ON CONFLICT (token_id) DO UPDATE SET
         display_name = EXCLUDED.display_name,
         image_url = EXCLUDED.image_url,
         x_url = EXCLUDED.x_url,
         telegram_url = EXCLUDED.telegram_url,
         website_url = EXCLUDED.website_url,
         updated_at = now()`,
      [
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
