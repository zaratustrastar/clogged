// Central, validated access to every NEXT_PUBLIC_* env var the app needs.
// Nothing here is a real value - it's all provided by the deployment
// environment (/opt/clogged/.env.production on the production VPS; see
// .env.production.example and VPS_RUNBOOK.md). Reading through this module
// instead of process.env directly means:
//   - one place lists every variable the app actually needs
//   - `isProtocolConfigured` gives every page a single, consistent way to
//     render a "not configured yet" state instead of crashing or faking data

function optional(name: string): string | undefined {
  return process.env[name] || undefined;
}

export const env = {
  reownProjectId: optional("NEXT_PUBLIC_REOWN_PROJECT_ID"),

  chainId: optional("NEXT_PUBLIC_ROBINHOOD_CHAIN_ID"),
  rpcUrl: optional("NEXT_PUBLIC_ROBINHOOD_RPC_URL"),
  explorerUrl: optional("NEXT_PUBLIC_ROBINHOOD_EXPLORER_URL"),
  deploymentBlock: optional("NEXT_PUBLIC_DEPLOYMENT_BLOCK"),
  appUrl: optional("NEXT_PUBLIC_APP_URL"), // e.g. https://clog.run - used for absolute URLs

  tickerRegistry: optional("NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS"),
  tickerNFT: optional("NEXT_PUBLIC_TICKER_NFT_ADDRESS"),
  eligibilityRegistry: optional("NEXT_PUBLIC_ELIGIBILITY_REGISTRY_ADDRESS"),
  roundManager: optional("NEXT_PUBLIC_ROUND_MANAGER_ADDRESS"),
  rewardVault: optional("NEXT_PUBLIC_REWARD_VAULT_ADDRESS"),
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
