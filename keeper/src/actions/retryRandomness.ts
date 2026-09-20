import type { Clients } from "../clients.js";
import type { KeeperConfig } from "../config.js";
import type { ActionLock } from "../lock.js";
import type { RoundLedger } from "../roundLedger.js";
import { roundManagerAbi } from "../abis/roundManager.js";

/**
 * requestRandomnessForRound(roundId) is `external`, no access modifier -
 * confirmed directly against RoundManager.sol's own source and doc comment
 * ("Permissionless retry: ... anyone can retry it later, as many times as
 * needed, for as long as it keeps failing"). closeRoundAndOpenNext()
 * already attempts this automatically at close time when the round has
 * enough candidates; this action exists specifically for the case where
 * that automatic attempt reverted (e.g. the provider was temporarily
 * underfunded, CCIP briefly unavailable).
 *
 * NO FIXED LOOKBACK HORIZON: which roundIds might need a retry comes from
 * `ledger` (see roundLedger.ts), reconstructed from real RoundClosed/
 * RandomnessRequested/RoundSettled event history starting at
 * deploymentBlock - not from scanning only the last N rounds. A round
 * closed long before the keeper was last online is found exactly the same
 * way as one closed a minute ago, because RoundManager itself places no
 * age limit on when requestRandomnessForRound remains callable (confirmed
 * directly against its source).
 *
 * Naturally idempotent at the contract level: requestRandomnessForRound
 * itself requires !randomnessRequested and !settled, so a stale retry
 * attempt against an already-resolved round simply reverts harmlessly.
 */
export async function retryFailedRandomness(
  config: KeeperConfig,
  clients: Clients,
  lock: ActionLock,
  ledger: RoundLedger
): Promise<{ acted: boolean; detail: string }[]> {
  const results: { acted: boolean; detail: string }[] = [];

  const dueRoundIds = ledger.needsRandomnessRetry();

  for (const roundId of dueRoundIds) {
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
    results.push({ acted: false, detail: `no closed, drawable, unrequested rounds found (ledger tracking ${ledger.outstandingCount} closed round(s) total)` });
  }
  return results;
}
