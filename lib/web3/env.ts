// Central, validated access to every NEXT_PUBLIC_* env var the app needs.
// Nothing here is a real value - it's all provided by the deployment
// environment (/opt/clogged/.env.production on the production VPS; see
// .env.production.example and VPS_RUNBOOK.md). Reading through this module
// instead of process.env directly means:
//   - one place lists every variable the app actually needs
//   - `isProtocolConfigured` gives every page a single, consistent way to
//     render a "not configured yet" state instead of crashing or faking data
//
// CRITICAL: every access below must be a literal `process.env.NEXT_PUBLIC_X`
// member expression, never a computed/bracket-style lookup built from a
// variable. Next.js inlines NEXT_PUBLIC_* values at build time via static,
// AST-based text replacement - it scans the source for that exact literal
// syntactic pattern and substitutes the real value directly into the
// compiled bundle. It cannot resolve a computed property access, because
// there is no way to statically determine what string a variable will
// hold at runtime. A dynamic accessor here doesn't fail loudly - it just
// silently inlines to nothing, so every value reads as undefined in the
// browser even when the real value was genuinely present at build time
// (this exact bug shipped once already: a small helper function took the
// variable name as a parameter and indexed into process.env with it -
// looked reasonable and passed every local check, since plain Node.js
// resolves a computed property access on process.env just fine; the
// failure is specific to Next.js's bundler, not JavaScript itself, and
// only shows up in a real production build).
// See lib/web3/env.test.ts for the regression test this maps to.

export const env = {
  reownProjectId: process.env.NEXT_PUBLIC_REOWN_PROJECT_ID || undefined,

  chainId: process.env.NEXT_PUBLIC_ROBINHOOD_CHAIN_ID || undefined,
  rpcUrl: process.env.NEXT_PUBLIC_ROBINHOOD_RPC_URL || undefined,
  explorerUrl: process.env.NEXT_PUBLIC_ROBINHOOD_EXPLORER_URL || undefined,
  deploymentBlock: process.env.NEXT_PUBLIC_DEPLOYMENT_BLOCK || undefined,
  appUrl: process.env.NEXT_PUBLIC_APP_URL || undefined, // e.g. https://clog.run - used for absolute URLs

  tickerRegistry: process.env.NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS || undefined,
  tickerNFT: process.env.NEXT_PUBLIC_TICKER_NFT_ADDRESS || undefined,
  eligibilityRegistry: process.env.NEXT_PUBLIC_ELIGIBILITY_REGISTRY_ADDRESS || undefined,
  roundManager: process.env.NEXT_PUBLIC_ROUND_MANAGER_ADDRESS || undefined,
  rewardVault: process.env.NEXT_PUBLIC_REWARD_VAULT_ADDRESS || undefined,

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
 * never fall back to fake/sample data. */
export const isProtocolConfigured = Boolean(
  env.chainId &&
    env.rpcUrl &&
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
