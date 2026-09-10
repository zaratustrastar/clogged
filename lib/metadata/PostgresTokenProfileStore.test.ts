import { describe, it, expect, afterAll } from "vitest";
import { PostgresTokenProfileStore } from "@/lib/metadata/PostgresTokenProfileStore";
import { getPool } from "@/lib/db/pool";

// Requires a real, already-migrated Postgres reachable via DATABASE_URL - see
// package.json's test script / DEPLOY_MAINNET.md for how this is run in CI
// and locally. Deliberately not mocked: the whole point of this suite is to
// exercise the real upsert semantics against a real database, not a
// simulation of one.
describe("PostgresTokenProfileStore", () => {
  const store = new PostgresTokenProfileStore();

  afterAll(async () => {
    const pool = getPool();
    await pool.query("DELETE FROM token_profiles WHERE token_id >= 900000"); // test-range cleanup
    await pool.end();
  });

  it("returns null for a tokenId that has never been set", async () => {
    const profile = await store.get(900001);
    expect(profile).toBeNull();
  });

  it("set() then get() round-trips every field correctly", async () => {
    const result = await store.set({
      tokenId: 900002,
      displayName: "Cat Coin",
      imageUrl: "https://example.com/cat.png",
      xUrl: "https://x.com/catcoin",
      telegramUrl: "https://t.me/catcoin",
      websiteUrl: "https://catcoin.example",
    });
    expect(result.persisted).toBe(true);

    const profile = await store.get(900002);
    expect(profile).toEqual({
      tokenId: 900002,
      displayName: "Cat Coin",
      imageUrl: "https://example.com/cat.png",
      xUrl: "https://x.com/catcoin",
      telegramUrl: "https://t.me/catcoin",
      websiteUrl: "https://catcoin.example",
    });
  });

  it("set() twice for the same tokenId upserts rather than erroring or duplicating", async () => {
    await store.set({ tokenId: 900003, displayName: "First Name" });
    await store.set({ tokenId: 900003, displayName: "Corrected Name" });

    const profile = await store.get(900003);
    expect(profile?.displayName).toBe("Corrected Name");

    const pool = getPool();
    const { rows } = await pool.query("SELECT count(*) FROM token_profiles WHERE token_id = $1", [900003]);
    expect(Number(rows[0].count)).toBe(1); // exactly one row, not two
  });

  it("partial fields are stored as undefined on read, not empty strings or errors", async () => {
    await store.set({ tokenId: 900004, displayName: "Only A Name" });
    const profile = await store.get(900004);
    expect(profile?.displayName).toBe("Only A Name");
    expect(profile?.imageUrl).toBeUndefined();
    expect(profile?.xUrl).toBeUndefined();
  });

  it("profiles for different tokenIds never collide with each other", async () => {
    await store.set({ tokenId: 900005, displayName: "Token Five" });
    await store.set({ tokenId: 900006, displayName: "Token Six" });

    const five = await store.get(900005);
    const six = await store.get(900006);
    expect(five?.displayName).toBe("Token Five");
    expect(six?.displayName).toBe("Token Six");
  });
});
