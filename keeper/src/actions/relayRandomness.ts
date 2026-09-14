import type { Clients } from "../clients.js";
import type { KeeperConfig } from "../config.js";
import type { ActionLock } from "../lock.js";
import { roundManagerAbi } from "../abis/roundManager.js";
import { vrfWrapperOnArbitrumAbi } from "../abis/vrfWrapperOnArbitrum.js";

/**
 * relayRandomness(originalRequestId) is `external`, no access modifier -
 * confirmed directly against VRFWrapperOnArbitrum.sol's own source and doc
 * comment ("Permissionless: relays an already-fulfilled, immutably stored
 * random word to Robinhood Chain via CCIP. Safe to call repeatedly if a
 * prior attempt reverted").
 *
 * fulfillRandomWords() itself (the actual VRF coordinator callback that
 * marks a request `fulfilled`) is Chainlink infrastructure's own job, not
 * this keeper's - this action only ever relays an ALREADY-fulfilled word
 * onward, never triggers fulfillment itself.
 *
 * Which requestIds to check comes from the Robinhood side, not a direct
 * Arbitrum-side enumeration (the wrapper exposes no "list all request ids"
 * getter): any round with randomnessRequested=true and settled=false has a
 * real randomnessRequestId that may now be fulfilled and awaiting relay.
 *
 * Naturally idempotent at the contract level: relayRandomness itself
 * requires !relayed, so a redundant call against an already-relayed
 * request simply reverts harmlessly.
 */
const LOOKBACK_ROUNDS = 20n;

export async function relayFulfilledRandomness(
  config: KeeperConfig,
  clients: Clients,
  lock: ActionLock
): Promise<{ acted: boolean; detail: string }[]> {
  const results: { acted: boolean; detail: string }[] = [];

  const currentRoundId = (await clients.robinhoodPublic.readContract({
    address: config.roundManager,
    abi: roundManagerAbi,
    functionName: "currentRoundId",
  })) as bigint;

  const earliestToCheck = currentRoundId > LOOKBACK_ROUNDS ? currentRoundId - LOOKBACK_ROUNDS : 1n;

  for (let roundId = earliestToCheck; roundId < currentRoundId; roundId++) {
    const round = (await clients.robinhoodPublic.readContract({
      address: config.roundManager,
      abi: roundManagerAbi,
      functionName: "getRound",
      args: [roundId],
    })) as {
      randomnessRequested: boolean;
      randomnessRequestId: bigint;
      settled: boolean;
    };

    if (!round.randomnessRequested || round.settled) continue;

    const requestId = round.randomnessRequestId;
    const fulfilledRequest = (await clients.arbitrumPublic.readContract({
      address: config.arbitrumVrfWrapper,
      abi: vrfWrapperOnArbitrumAbi,
      functionName: "fulfilledRequests",
      args: [requestId],
    })) as [bigint, boolean, boolean]; // [randomWord, fulfilled, relayed] - tuple return, no named-field access for this one

    const [, fulfilled, relayed] = fulfilledRequest;
    if (!fulfilled || relayed) continue;

    const lockKey = `relay-randomness-request-${requestId}`;
    if (await lock.isInFlight(lockKey, { robinhood: clients.robinhoodPublic, arbitrum: clients.arbitrumPublic })) {
      results.push({ acted: false, detail: `relay for request ${requestId} (round ${roundId}) already in flight, skipping` });
      continue;
    }

    if (config.dryRun) {
      results.push({ acted: true, detail: `[dry-run] would call relayRandomness(${requestId}) on Arbitrum (round ${roundId})` });
      continue;
    }

    const txHash = await clients.arbitrumWallet.writeContract({
      address: config.arbitrumVrfWrapper,
      abi: vrfWrapperOnArbitrumAbi,
      functionName: "relayRandomness",
      args: [requestId],
      chain: clients.arbitrumWallet.chain,
      account: clients.arbitrumWallet.account!,
    });
    lock.acquire(lockKey, txHash, "arbitrum");
    results.push({ acted: true, detail: `relayRandomness(${requestId}) for round ${roundId} submitted on Arbitrum: ${txHash}` });
  }

  if (results.length === 0) {
    results.push({ acted: false, detail: "no fulfilled-but-unrelayed randomness requests found in lookback window" });
  }
  return results;
}
