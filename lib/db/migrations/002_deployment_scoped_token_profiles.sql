-- Makes token_profiles deployment-aware: a bare token_id is only unique
-- WITHIN one specific (chain, TickerRegistry) deployment - a fresh canary
-- deployment's TickerRegistry starts its own tokenId numbering back at 1,
-- which would otherwise collide with the existing HOOD deployment's own
-- tokenId=1 in this same table.
--
-- NON-DESTRUCTIVE: every existing row is preserved exactly as-is. Existing
-- rows are backfilled as belonging to the current, already-live HOOD
-- deployment (Robinhood Chain, chain id 4663; TickerRegistry
-- 0xaf5b710DE2EafD2614D2CFFb01B953d8c664Ea33) - the only deployment that
-- could have written any of them, since this table predates the v4/canary
-- work entirely.
--
-- Safe to run against a table that already has rows: backfill happens
-- BEFORE the primary key is replaced, so no existing row can violate the
-- new composite constraint (chain_id, ticker_registry_address, token_id) -
-- token_id was already globally unique under the old single-column primary
-- key, and every row gets the identical (chain_id, ticker_registry_address)
-- pair here.

ALTER TABLE token_profiles
    ADD COLUMN IF NOT EXISTS chain_id BIGINT,
    ADD COLUMN IF NOT EXISTS ticker_registry_address TEXT;

UPDATE token_profiles
SET chain_id = 4663,
    ticker_registry_address = '0xaf5b710DE2EafD2614D2CFFb01B953d8c664Ea33'
WHERE chain_id IS NULL OR ticker_registry_address IS NULL;

ALTER TABLE token_profiles
    ALTER COLUMN chain_id SET NOT NULL,
    ALTER COLUMN ticker_registry_address SET NOT NULL;

-- Drop the old single-column primary key and replace it with the composite
-- deployment-scoped one. token_id alone is no longer required to be
-- globally unique across the whole table - only within one deployment.
ALTER TABLE token_profiles DROP CONSTRAINT IF EXISTS token_profiles_pkey;
ALTER TABLE token_profiles
    ADD PRIMARY KEY (chain_id, ticker_registry_address, token_id);

-- Fast lookup by ticker_registry_address alone is useful for future
-- deployment-scoped admin/debug queries (e.g. "show me everything the
-- canary has ever written") without needing the full composite key.
CREATE INDEX IF NOT EXISTS idx_token_profiles_deployment
    ON token_profiles (chain_id, ticker_registry_address);
