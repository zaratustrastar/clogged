import type { Address } from "viem";
import { env } from "./env";

/** Real, env-driven contract addresses. Every value is `undefined` until
 * the corresponding NEXT_PUBLIC_*_ADDRESS variable is set in the deployment
 * environment - see env.ts's `isProtocolConfigured` for the single check
 * pages should use before reading from these. */
export const addresses = {
  tickerRegistry: env.tickerRegistry as Address | undefined,
  tickerNFT: env.tickerNFT as Address | undefined,
  eligibilityRegistry: env.eligibilityRegistry as Address | undefined,
  roundManager: env.roundManager as Address | undefined,
  rewardVault: env.rewardVault as Address | undefined,

  v4PoolManager: env.v4PoolManager as Address | undefined,
  universalRouter: env.universalRouter as Address | undefined,
  permit2: env.permit2 as Address | undefined,
  clogV4Hook: env.clogV4Hook as Address | undefined,
};
