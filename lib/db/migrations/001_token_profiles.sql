-- Off-chain presentation data only. Onchain state (ticker existence, tokenId,
-- TickerNFT ownership, meme token/market addresses, balances, reserves,
-- progress, qualification, rounds, rewards, trading state) remains
-- authoritative on Robinhood Chain and is never duplicated here.
CREATE TABLE IF NOT EXISTS token_profiles (
    token_id BIGINT PRIMARY KEY,
    display_name TEXT,
    image_url TEXT,
    x_url TEXT,
    telegram_url TEXT,
    website_url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
