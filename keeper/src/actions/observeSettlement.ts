import type { Clients } from "../clients.js";
import type { KeeperConfig } from "../config.js";
import { roundManagerAbi } from "../abis/roundManager.js";

/**
 * Purely read-only - onRandomnessReceived (the function that actually
 * marks a round settled) is restricted to `msg.sender ==
 * address(randomnessProvider)` (confirmed directly against
 * RoundManager.sol's own source), triggered automatically once
 * ChainlinkRandomnessProvider's own CCIP receive handler processes the
 * relayed message. This keeper never calls it and never could - this
 * action exists only to observe and log, so an operator (or external
 * alerting watching these log lines) notices if a round stays requested-
 * but-unsettled for an unusually long time, which would indicate a
 * problem elsewhere in the pipeline (CCIP delivery stuck, the provider's
 * own receive handler reverting, etc.) worth investigating - never
 * something this keeper attempts to fix directly.
 */
const LOOKBACK_ROUNDS = 20n;
/** How long a round can sit requested-but-unsettled before this action logs
 * a WARNING instead of an INFO line - generous, since real CCIP delivery
 * can legitimately take a while under network congestion. */
const STUCK_WARNING_SECONDS = 30 * 60; // 30 minutes

export async function observeSettlement(config: KeeperConfig, clients: Clients): Promise<{ level: "info" | "warn"; detail: string }[]> {
  const results: { level: "info" | "warn"; detail: string }[] = [];

  const currentRoundId = (await clients.robinhoodPublic.readContract({
    address: config.roundManager,
    abi: roundManagerAbi,
    functionName: "currentRoundId",
  })) as bigint;

  const earliestToCheck = currentRoundId > LOOKBACK_ROUNDS ? currentRoundId - LOOKBACK_ROUNDS : 1n;
  const nowSec = Math.floor(Date.now() / 1000);

  for (let roundId = earliestToCheck; roundId < currentRoundId; roundId++) {
    const round = (await clients.robinhoodPublic.readContract({
      address: config.roundManager,
      abi: roundManagerAbi,
      functionName: "getRound",
      args: [roundId],
    })) as {
      closeTime: bigint;
      drawSkipped: boolean;
      randomnessRequested: boolean;
      settled: boolean;
      winnerTokenId: bigint;
    };

    if (round.drawSkipped) continue; // nothing to settle
    if (round.settled) {
      results.push({ level: "info", detail: `round ${roundId} settled, winner tokenId ${round.winnerTokenId}` });
      continue;
    }
    if (!round.randomnessRequested) continue; // handled by retryRandomness action, not this one

    const ageSinceClose = nowSec - Number(round.closeTime);
    if (ageSinceClose > STUCK_WARNING_SECONDS) {
      results.push({
        level: "warn",
        detail: `round ${roundId} requested but UNSETTLED for ${ageSinceClose}s since close - investigate CCIP delivery / provider receive handler`,
      });
    } else {
      results.push({ level: "info", detail: `round ${roundId} requested, awaiting settlement (${ageSinceClose}s since close)` });
    }
  }

  return results;
}
