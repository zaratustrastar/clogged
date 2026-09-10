import "server-only";
import { Pool } from "pg";

/**
 * Server-only Postgres pool singleton. Importing this file from a client
 * component would break the browser bundle ("server-only" enforces that at
 * build time) - this must only ever be reached from API routes or other
 * server-side code, never from lib/metadata/TokenProfileStore.ts (the
 * client-safe interface the rest of the app actually imports).
 *
 * Reuses the single pool across hot-reloads in dev (Next.js re-evaluates
 * modules on every request in some dev modes) via a global, matching the
 * standard pattern for this exact problem.
 */

declare global {
  // eslint-disable-next-line no-var
  var __clogPgPool: Pool | undefined;
}

function createPool(): Pool {
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    throw new Error(
      "DATABASE_URL is not set - Postgres-backed features (token profiles) are unavailable until it is configured."
    );
  }
  return new Pool({ connectionString });
}

export function getPool(): Pool {
  if (!global.__clogPgPool) {
    global.__clogPgPool = createPool();
  }
  return global.__clogPgPool;
}

export function isDatabaseConfigured(): boolean {
  return Boolean(process.env.DATABASE_URL);
}
