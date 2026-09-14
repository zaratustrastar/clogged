import type { Clients } from "../clients.js";
import type { KeeperConfig } from "../config.js";
import type { RoundLedger } from "../roundLedger.js";
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
 * but-unsettled for an unusually long time.
 *
 * NO FIXED LOOKBACK HORIZON, for the same reason retryRandomness.ts and
 * relayRandomness.ts have none (see roundLedger.ts): a round outstanding
 * from long before the keeper was last online is reported exactly the
 * same way as a recent one - `ledger.outstandingRequested()` is a small,
 * precomputed set with no age limit built in, reconstructed from real
 * event history rather than a bounded scan window.
 */
/** How long a round can sit requested-but-unsettled before this action logs
 * a WARNING instead of an INFO line - generous, since real CCIP delivery
 * can legitimately take a while under network congestion. */
const STUCK_WARNING_SECONDS = 30 * 60; // 30 minutes

export async function observeSettlement(
  config: KeeperConfig,
  clients: Clients,
  ledger: RoundLedger
): Promise<{ level: "info" | "warn"; detail: string }[]> {
  const results: { level: "info" | "warn"; detail: string }[] = [];
  const nowSec = Math.floor(Date.now() / 1000);

  for (const roundId of ledger.outstandingRequested()) {
    const round = (await clients.robinhoodPublic.readContract({
      address: config.roundManager,
      abi: roundManagerAbi,
      functionName: "getRound",
      args: [roundId],
    })) as { closeTime: bigint; settled: boolean; winnerTokenId: bigint };

    if (round.settled) {
      results.push({ level: "info", detail: `round ${roundId} settled, winner tokenId ${round.winnerTokenId}` });
      continue;
    }

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

  if (results.length === 0) {
    results.push({ level: "info", detail: "no rounds currently requested-and-unsettled" });
  }
  return results;
}
