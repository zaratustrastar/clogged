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

  it("every remaining NEXT_PUBLIC_ variable is read via a literal process.env.NEXT_PUBLIC_X expression", () => {
    // NEXT_PUBLIC_ROBINHOOD_CHAIN_ID, NEXT_PUBLIC_DEPLOYMENT_BLOCK, and the
    // five NEXT_PUBLIC_*_ADDRESS contract variables are deliberately absent
    // from this list - they no longer come from process.env at all, having
    // moved to the tracked deployment manifest (see the manifest-import
    // test below and docs/DEPLOYMENTS.md).
    const expectedVars = [
      "NEXT_PUBLIC_REOWN_PROJECT_ID",
      "NEXT_PUBLIC_ROBINHOOD_RPC_URL",
      "NEXT_PUBLIC_ROBINHOOD_EXPLORER_URL",
      "NEXT_PUBLIC_APP_URL",
    ];
    for (const name of expectedVars) {
      expect(source).toContain(`process.env.${name}`);
    }
  });

  it("never reads chainId/deploymentBlock/the five protocol addresses from process.env", () => {
    // The exact regression this guards against: an old .env.production on
    // the VPS still setting one of these seven variables must never be
    // able to silently override the tracked deployment manifest again -
    // the only way that guarantee holds is if env.ts never reads these
    // names from process.env in the first place.
    const removedVars = [
      "NEXT_PUBLIC_ROBINHOOD_CHAIN_ID",
      "NEXT_PUBLIC_DEPLOYMENT_BLOCK",
      "NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS",
      "NEXT_PUBLIC_TICKER_NFT_ADDRESS",
      "NEXT_PUBLIC_ELIGIBILITY_REGISTRY_ADDRESS",
      "NEXT_PUBLIC_ROUND_MANAGER_ADDRESS",
      "NEXT_PUBLIC_REWARD_VAULT_ADDRESS",
    ];
    for (const name of removedVars) {
      expect(source).not.toContain(`process.env.${name}`);
    }
  });

  it("chainId/deploymentBlock/the five protocol addresses are sourced from the tracked deployment manifest", () => {
    expect(source).toContain('import deploymentManifest from "@/deployments/robinhood-mainnet.json"');
    expect(source).toContain("deploymentManifest.chainId");
    expect(source).toContain("deploymentManifest.deploymentBlock");
    expect(source).toContain("deploymentManifest.contracts.tickerRegistry");
    expect(source).toContain("deploymentManifest.contracts.tickerNFT");
    expect(source).toContain("deploymentManifest.contracts.eligibilityRegistry");
    expect(source).toContain("deploymentManifest.contracts.roundManager");
    expect(source).toContain("deploymentManifest.contracts.rewardVault");
  });
});

describe("env.ts values actually resolve to the tracked manifest's real content", () => {
  it("env.tickerRegistry/chainId match deployments/robinhood-mainnet.json exactly, not any env var", async () => {
    const manifest = JSON.parse(readFileSync(path.join(process.cwd(), "deployments/robinhood-mainnet.json"), "utf8"));
    const { env } = await import("./env");
    expect(env.chainId).toBe(String(manifest.chainId));
    expect(env.tickerRegistry).toBe(manifest.contracts.tickerRegistry);
    expect(env.tickerNFT).toBe(manifest.contracts.tickerNFT);
    expect(env.eligibilityRegistry).toBe(manifest.contracts.eligibilityRegistry);
    expect(env.roundManager).toBe(manifest.contracts.roundManager);
    expect(env.rewardVault).toBe(manifest.contracts.rewardVault);
  });
});
