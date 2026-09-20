import type { Clients } from "../clients.js";
import type { KeeperConfig } from "../config.js";
import type { ActionLock } from "../lock.js";
import { roundManagerAbi } from "../abis/roundManager.js";

/**
 * closeRoundAndOpenNext() is `external`, no access modifier - confirmed
 * directly against RoundManager.sol's own source, not assumed. It also
 * enforces `block.timestamp >= currentRoundOpenTime + roundDuration`
 * itself, so this action is naturally idempotent at the contract level:
 * calling it before a round is due simply reverts, and once it has
 * succeeded, currentRoundId has already advanced, so a second, redundant
 * call in the same poll cycle would target a round that isn't due yet
 * either. The lock below exists only to avoid wasting gas on a second,
 * purely redundant transaction while the first is still pending.
 */
export async function closeDueRounds(
  config: KeeperConfig,
  clients: Clients,
  lock: ActionLock
): Promise<{ acted: boolean; detail: string }> {
  const [currentRoundId, currentRoundOpenTime, roundDuration] = await Promise.all([
    clients.robinhoodPublic.readContract({
      address: config.roundManager,
      abi: roundManagerAbi,
      functionName: "currentRoundId",
    }) as Promise<bigint>,
    clients.robinhoodPublic.readContract({
      address: config.roundManager,
      abi: roundManagerAbi,
      functionName: "currentRoundOpenTime",
    }) as Promise<bigint>,
    clients.robinhoodPublic.readContract({
      address: config.roundManager,
      abi: roundManagerAbi,
      functionName: "ROUND_DURATION",
    }) as Promise<bigint>,
  ]);

  const nowSec = BigInt(Math.floor(Date.now() / 1000));
  const dueAt = currentRoundOpenTime + roundDuration;
  if (nowSec < dueAt) {
    return { acted: false, detail: `round ${currentRoundId} not due yet (due at ${dueAt}, now ${nowSec})` };
  }

  const lockKey = `close-round-${currentRoundId}`;
  if (await lock.isInFlight(lockKey, { robinhood: clients.robinhoodPublic, arbitrum: clients.arbitrumPublic })) {
    return { acted: false, detail: `close for round ${currentRoundId} already in flight, skipping` };
  }

  if (config.dryRun) {
    return { acted: true, detail: `[dry-run] would call closeRoundAndOpenNext() for round ${currentRoundId}` };
  }

  const txHash = await clients.robinhoodWallet.writeContract({
    address: config.roundManager,
    abi: roundManagerAbi,
    functionName: "closeRoundAndOpenNext",
    chain: clients.robinhoodWallet.chain,
    account: clients.robinhoodWallet.account!,
  });
  lock.acquire(lockKey, txHash, "robinhood");
  return { acted: true, detail: `closeRoundAndOpenNext() for round ${currentRoundId} submitted: ${txHash}` };
}
