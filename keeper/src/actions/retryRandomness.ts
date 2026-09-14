import type { Clients } from "../clients.js";
import type { KeeperConfig } from "../config.js";
import type { ActionLock } from "../lock.js";
import { roundManagerAbi } from "../abis/roundManager.js";

/**
 * requestRandomnessForRound(roundId) is `external`, no access modifier -
 * confirmed directly against RoundManager.sol's own source and doc comment
 * ("Permissionless retry: ... anyone can retry it later, as many times as
 * needed, for as long as it keeps failing"). closeRoundAndOpenNext()
 * already attempts this automatically at close time when the round has
 * enough candidates; this action exists specifically for the case where
 * that automatic attempt reverted (e.g. the provider was temporarily
 * underfunded, CCIP briefly unavailable) - the contract's own
 * RandomnessRequestFailed event marks this, but polling round state
 * directly is simpler and sufficient for a v1 keeper.
 *
 * Naturally idempotent at the contract level: requestRandomnessForRound
 * itself requires !randomnessRequested and !settled, so a stale retry
 * attempt against an already-resolved round simply reverts harmlessly.
 */
const LOOKBACK_ROUNDS = 20n;

export async function retryFailedRandomness(
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
      closed: boolean;
      drawSkipped: boolean;
      randomnessRequested: boolean;
      settled: boolean;
    };

    if (!round.closed) continue; // shouldn't happen for roundId < currentRoundId, but be defensive
    if (round.drawSkipped) continue; // fewer than MIN_DRAW_CANDIDATES - no randomness to request
    if (round.randomnessRequested) continue; // already requested (successfully) - nothing to retry
    if (round.settled) continue; // already resolved

    const lockKey = `retry-randomness-round-${roundId}`;
    if (await lock.isInFlight(lockKey, { robinhood: clients.robinhoodPublic, arbitrum: clients.arbitrumPublic })) {
      results.push({ acted: false, detail: `retry for round ${roundId} already in flight, skipping` });
      continue;
    }

    if (config.dryRun) {
      results.push({ acted: true, detail: `[dry-run] would call requestRandomnessForRound(${roundId})` });
      continue;
    }

    const txHash = await clients.robinhoodWallet.writeContract({
      address: config.roundManager,
      abi: roundManagerAbi,
      functionName: "requestRandomnessForRound",
      args: [roundId],
      chain: clients.robinhoodWallet.chain,
      account: clients.robinhoodWallet.account!,
    });
    lock.acquire(lockKey, txHash, "robinhood");
    results.push({ acted: true, detail: `requestRandomnessForRound(${roundId}) submitted: ${txHash}` });
  }

  if (results.length === 0) {
    results.push({ acted: false, detail: "no closed, drawable, unrequested rounds found in lookback window" });
  }
  return results;
}
