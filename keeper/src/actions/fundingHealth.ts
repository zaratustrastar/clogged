import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import type { Address } from "viem";
import type { Clients } from "../clients.js";
import type { KeeperConfig } from "../config.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const VRF_SUBSCRIPTION_API_ABI = [
  {
    type: "function",
    name: "getSubscription",
    stateMutability: "view",
    inputs: [{ name: "subId", type: "uint256" }],
    outputs: [
      { name: "balance", type: "uint96" }, // LINK
      { name: "nativeBalance", type: "uint96" }, // native ETH
      { name: "reqCount", type: "uint64" },
      { name: "subOwner", type: "address" },
      { name: "consumers", type: "address[]" },
    ],
  },
] as const;

/**
 * Read-only balance checks only - NEVER sends a transaction, NEVER
 * transfers funds anywhere, on either chain. v1 deliberately does no
 * automatic funding at all (see README.md): a keeper that can move funds
 * on its own is a materially different, higher-risk design than one that
 * only ever calls fixed, permissionless, no-value protocol functions -
 * this stays in the simpler, safer category. Every warning here is meant
 * for an operator (or the operator's own external alerting watching these
 * log lines) to act on manually.
 */
export async function checkFundingHealth(config: KeeperConfig, clients: Clients): Promise<{ level: "info" | "warn"; detail: string }[]> {
  const results: { level: "info" | "warn"; detail: string }[] = [];

  const [providerBalance, wrapperBalance, keeperRobinhoodBalance, keeperArbitrumBalance] = await Promise.all([
    clients.robinhoodPublic.getBalance({ address: config.chainlinkRandomnessProvider }),
    clients.arbitrumPublic.getBalance({ address: config.arbitrumVrfWrapper }),
    clients.robinhoodPublic.getBalance({ address: clients.keeperAddress }),
    clients.arbitrumPublic.getBalance({ address: clients.keeperAddress }),
  ]);

  const checks: { label: string; balance: bigint }[] = [
    { label: `ChainlinkRandomnessProvider (${config.chainlinkRandomnessProvider}) ETH on Robinhood Chain`, balance: providerBalance },
    { label: `VRFWrapperOnArbitrum (${config.arbitrumVrfWrapper}) ETH on Arbitrum One`, balance: wrapperBalance },
    { label: `Keeper EOA (${clients.keeperAddress}) ETH on Robinhood Chain`, balance: keeperRobinhoodBalance },
    { label: `Keeper EOA (${clients.keeperAddress}) ETH on Arbitrum One`, balance: keeperArbitrumBalance },
  ];

  for (const check of checks) {
    if (check.balance < config.lowBalanceWarningThresholdWei) {
      results.push({
        level: "warn",
        detail: `LOW BALANCE: ${check.label} = ${check.balance} wei (threshold: ${config.lowBalanceWarningThresholdWei} wei) - fund manually, this keeper never auto-funds`,
      });
    } else {
      results.push({ level: "info", detail: `${check.label} = ${check.balance} wei` });
    }
  }

  // VRF subscription LINK + native balance - the manifest's own
  // arbitrumVrfCoordinator field, read directly rather than assumed.
  const manifestPath = path.join(__dirname, "../../../deployments/robinhood-mainnet.json");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as {
    ["$notReadByFrontend"]: { arbitrumVrfCoordinator?: Address };
  };
  const coordinator = manifest["$notReadByFrontend"].arbitrumVrfCoordinator;
  if (coordinator) {
    try {
      const [linkBalance, nativeBalance] = (await clients.arbitrumPublic.readContract({
        address: coordinator,
        abi: VRF_SUBSCRIPTION_API_ABI,
        functionName: "getSubscription",
        args: [config.arbitrumVrfSubscriptionId],
      })) as [bigint, bigint, bigint, Address, Address[]];

      results.push({ level: "info", detail: `VRF subscription ${config.arbitrumVrfSubscriptionId} LINK balance = ${linkBalance}` });
      results.push({ level: "info", detail: `VRF subscription ${config.arbitrumVrfSubscriptionId} native balance = ${nativeBalance}` });
      if (linkBalance < 1_000_000_000_000_000_000n) {
        // Chainlink recommends keeping a healthy multi-request buffer of
        // LINK; a bare 1 LINK floor is a conservative, simple v1 threshold
        // - not a Chainlink-published minimum.
        results.push({ level: "warn", detail: `VRF subscription ${config.arbitrumVrfSubscriptionId} LINK balance is low (${linkBalance} wei-LINK) - fund manually via the Chainlink VRF subscription manager` });
      }
    } catch (err) {
      results.push({ level: "warn", detail: `Could not read VRF subscription balance: ${(err as Error).message}` });
    }
  }

  return results;
}
