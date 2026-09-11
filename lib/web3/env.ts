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

export const deploymentBlockBigInt = env.deploymentBlock ? BigInt(env.deploymentBlock) : 0n;
