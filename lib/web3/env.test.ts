import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";

/**
 * Next.js inlines NEXT_PUBLIC_* environment variables at build time via
 * static, AST-based text replacement - it scans source code for the exact
 * literal pattern `process.env.NEXT_PUBLIC_X` and substitutes the real
 * value directly into the compiled bundle. It cannot resolve a computed
 * property access like `process.env[name]`, because there's no way to
 * statically determine what string a runtime variable will hold. This
 * failure mode is silent (no build error, no lint error, no test failure
 * under a normal runtime like vitest or Node itself, since plain
 * JavaScript resolves computed property access on process.env just fine)
 * - it only shows up as every NEXT_PUBLIC_* value reading as undefined in
 * an actual production browser bundle, which is exactly what happened
 * here: a real, correctly-set NEXT_PUBLIC_REOWN_PROJECT_ID silently became
 * undefined in production because it was read via
 * `process.env[name]` inside a helper function instead of a literal
 * `process.env.NEXT_PUBLIC_REOWN_PROJECT_ID` expression.
 *
 * This test can't simulate Next.js's real webpack-based inlining (that
 * would require running an actual `next build`, far heavier than a unit
 * test needs), so it does the next best thing: a direct static check of
 * env.ts's own source text for the exact dangerous pattern
 * (`process.env[`), which is a reliable, practical proxy that would have
 * caught the original bug and will catch it if ever reintroduced.
 */
describe("lib/web3/env.ts NEXT_PUBLIC_* access pattern", () => {
  const source = readFileSync(path.join(process.cwd(), "lib/web3/env.ts"), "utf8");

  it("never uses computed/bracket-notation process.env[...] access", () => {
    expect(source).not.toMatch(/process\.env\[/);
  });

  it("every NEXT_PUBLIC_ variable is read via a literal process.env.NEXT_PUBLIC_X expression", () => {
    const expectedVars = [
      "NEXT_PUBLIC_REOWN_PROJECT_ID",
      "NEXT_PUBLIC_ROBINHOOD_CHAIN_ID",
      "NEXT_PUBLIC_ROBINHOOD_RPC_URL",
      "NEXT_PUBLIC_ROBINHOOD_EXPLORER_URL",
      "NEXT_PUBLIC_DEPLOYMENT_BLOCK",
      "NEXT_PUBLIC_APP_URL",
      "NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS",
      "NEXT_PUBLIC_TICKER_NFT_ADDRESS",
      "NEXT_PUBLIC_ELIGIBILITY_REGISTRY_ADDRESS",
      "NEXT_PUBLIC_ROUND_MANAGER_ADDRESS",
      "NEXT_PUBLIC_REWARD_VAULT_ADDRESS",
    ];
    for (const name of expectedVars) {
      expect(source).toContain(`process.env.${name}`);
    }
  });
});
