// Central, validated access to every NEXT_PUBLIC_* env var the app needs,
// PLUS the tracked public deployment manifest (deployments/robinhood-mainnet.json)
// for the five protocol contract addresses, chain id, and deployment block -
// see docs/DEPLOYMENTS.md for why those seven specific values live in a
// tracked JSON file instead of .env.production: a stale
// NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS (etc.) left over in an old
// .env.production on the VPS must never silently override which deployment
// the frontend reads from after a `git pull` - the tracked manifest is
// unconditionally the single source of truth for those seven values, full
// stop, with no environment-variable override path at all.
//
// Everything else (RPC/explorer URLs, wallet connect, v4 trading addresses,
// app URL) remains an ordinary NEXT_PUBLIC_* env var, unchanged from before -
// this file's job is still exactly what its own name says: reading env.
// deploymentManifest is a plain, statically-resolved JSON import (Next.js's
// bundler resolves this via normal module resolution, completely unrelated
// to the NEXT_PUBLIC_* text-substitution mechanism described below - a JSON
// import is never subject to that inlining mechanism or its pitfalls).
//
// CRITICAL: every remaining process.env access below must be a literal
// `process.env.NEXT_PUBLIC_X` member expression, never a computed/bracket-style
// lookup built from a variable. Next.js inlines NEXT_PUBLIC_* values at
// build time via static, AST-based text replacement - it scans the source
// for that exact literal syntactic pattern and substitutes the real value
// directly into the compiled bundle. It cannot resolve a computed property
// access, because there is no way to statically determine what string a
// variable will hold at runtime. A dynamic accessor here doesn't fail
// loudly - it just silently inlines to nothing, so every value reads as
// undefined in the browser even when the real value was genuinely present
// at build time (this exact bug shipped once already: a small helper
// function took the variable name as a parameter and indexed into
// process.env with it - looked reasonable and passed every local check,
// since plain Node.js resolves a computed property access on process.env
// just fine; the failure is specific to Next.js's bundler, not JavaScript
// itself, and only shows up in a real production build).
// See lib/web3/env.test.ts for the regression test this maps to.

import deploymentManifest from "@/deployments/robinhood-mainnet.json";

export const env = {
  reownProjectId: process.env.NEXT_PUBLIC_REOWN_PROJECT_ID || undefined,

  // chainId/deploymentBlock/the five protocol addresses come from the
  // tracked deployment manifest, NOT from any NEXT_PUBLIC_* env var - see
  // this file's own header comment and docs/DEPLOYMENTS.md. Converted to
  // the same string-or-undefined shape every other field here uses, so
  // every downstream consumer (isProtocolConfigured, addresses.ts,
  // deploymentBlockBigInt, lib/web3/deployments.ts's getActiveDeployment)
  // needs no changes at all - only where these seven values originate has
  // changed.
  chainId: String(deploymentManifest.chainId),
  deploymentBlock: deploymentManifest.deploymentBlock != null ? String(deploymentManifest.deploymentBlock) : undefined,
  tickerRegistry: deploymentManifest.contracts.tickerRegistry || undefined,
  tickerNFT: deploymentManifest.contracts.tickerNFT || undefined,
  eligibilityRegistry: deploymentManifest.contracts.eligibilityRegistry || undefined,
  roundManager: deploymentManifest.contracts.roundManager || undefined,
  rewardVault: deploymentManifest.contracts.rewardVault || undefined,

  rpcUrl: process.env.NEXT_PUBLIC_ROBINHOOD_RPC_URL || undefined,
  explorerUrl: process.env.NEXT_PUBLIC_ROBINHOOD_EXPLORER_URL || undefined,
  appUrl: process.env.NEXT_PUBLIC_APP_URL || undefined, // e.g. https://clog.run - used for absolute URLs

  // v4 trading path - see docs/V4_TRADING.md. All five must be present for the v4 path to be
  // usable; v4TradingMode below is the single place that decides this, so pages/hooks
  // never have to re-derive that combined check themselves.
  v4TradingEnabledFlag: process.env.NEXT_PUBLIC_V4_TRADING_ENABLED || undefined,
  v4PoolManager: process.env.NEXT_PUBLIC_V4_POOL_MANAGER_ADDRESS || undefined,
  universalRouter: process.env.NEXT_PUBLIC_UNIVERSAL_ROUTER_ADDRESS || undefined,
  permit2: process.env.NEXT_PUBLIC_PERMIT2_ADDRESS || undefined,
  clogV4Hook: process.env.NEXT_PUBLIC_CLOG_V4_HOOK_ADDRESS || undefined,
} as const;

/** True once every address + network variable needed to read real protocol
 * state is present. Pages should check this before attempting reads, and
 * render an explicit "protocol contracts not configured" state otherwise -
 * never fall back to fake/sample data. Requires deploymentBlock too (not
 * just the five addresses/chainId/rpcUrl): scanning event logs from block 0
 * on a real chain is both slow and liable to be rejected outright by an RPC
 * provider for too large a range, so an unset deploymentBlock must keep the
 * whole app in the "not configured" state, never silently default to 0. */
export const isProtocolConfigured = Boolean(
  env.chainId &&
    env.rpcUrl &&
    env.deploymentBlock &&
    env.tickerRegistry &&
    env.tickerNFT &&
    env.eligibilityRegistry &&
    env.roundManager &&
    env.rewardVault
);

/** True once wallet connect can actually be offered. Reown AppKit requires
 * a project ID; without one, the Connect button should say so rather than
 * silently failing when clicked. */
export const isWalletConfigured = Boolean(env.reownProjectId);

/** Which trading path is actually active - a real three-state decision, not
 * a single boolean, because "flag on but misconfigured" must NEVER
 * silently behave like "flag off": that would mean an operator explicitly
 * turning v4 on gets direct trading with no indication anything is wrong.
 * - "direct": the flag is off (or unset) - use the existing, unmodified
 *   BondingCurveClog path exactly as before this feature existed.
 * - "v4": the flag is "true" AND every required v4 address is present -
 *   use the real Universal Router/PoolManager/ClogV4Hook path.
 * - "misconfigured": the flag is "true" but at least one required address
 *   is missing - trading must be DISABLED with an explicit configuration
 *   error, never silently downgraded to either other path. */
export type V4TradingMode = "direct" | "v4" | "misconfigured";

export const v4TradingMode: V4TradingMode = (() => {
  if (env.v4TradingEnabledFlag !== "true") return "direct";
  const allV4AddressesPresent = Boolean(
    env.v4PoolManager && env.universalRouter && env.permit2 && env.clogV4Hook
  );
  return allV4AddressesPresent ? "v4" : "misconfigured";
})();

export const deploymentBlockBigInt = env.deploymentBlock ? BigInt(env.deploymentBlock) : 0n;
