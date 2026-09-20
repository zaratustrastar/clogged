import type { Clients } from "../clients.js";
import type { KeeperConfig } from "../config.js";
import type { ActionLock } from "../lock.js";
import type { TokenWatchlist } from "../tokenWatchlist.js";
import { eligibilityRegistryAbi } from "../abis/eligibilityRegistry.js";

/**
 * qualify(tokenId) is `external`, no access modifier - confirmed directly
 * against EligibilityRegistry.sol's own source and doc comment ("a token
 * that has genuinely earned candidacy always has a trivial, one-transaction
 * path for anyone to lock it in before the round closes").
 *
 * A trade automatically qualifies a token via onTrade() -> _touch() -> the
 * contract's own internal maybeQualify path, so this keeper action exists
 * specifically for tokens that crossed the maturity threshold WITHOUT a
 * new trade happening afterward to trigger that automatically - exactly
 * the gap the permissionless qualify() function exists to close.
 *
 * NEVER reads aboveThresholdSince/isCandidate for every launched token
 * every poll (see tokenWatchlist.ts's own architecture notes for the full
 * design and why an event-driven approach is required - EligibilityRegistry
 * emits no above-threshold-start/reset event of its own, so trade activity
 * on each token's own market, via BondingCurveClog's real Bought/Sold
 * events, is what's watched instead). This action only ever reads
 * onchain state for watchlist.dueForCheck()'s own small, precomputed set -
 * active-streak tokens whose scheduled maturity time has already passed
 * and are not yet qualified for the current round - never the full
 * watchlist, and never the full tokenId space.
 */
export async function qualifyMaturedTokens(
  config: KeeperConfig,
  clients: Clients,
  lock: ActionLock,
  watchlist: TokenWatchlist
): Promise<{ acted: boolean; detail: string }[]> {
  const results: { acted: boolean; detail: string }[] = [];

  const added = await watchlist.scanForNewTokens();
  if (added > 0) {
    results.push({ acted: false, detail: `watchlist: discovered ${added} newly-registered token(s), now tracking ${watchlist.size} total` });
  }
  const traded = await watchlist.scanForTradeActivity();
  if (traded.length > 0) {
    results.push({
      acted: false,
      detail: `watchlist: ${traded.length} token(s) traded since last check, re-read (active streak count now ${watchlist.activeStreakCount})`,
    });
  }

  const [requiredAbsoluteSeconds, currentRoundId] = await Promise.all([
    clients.robinhoodPublic.readContract({
      address: config.eligibilityRegistry,
      abi: eligibilityRegistryAbi,
      functionName: "REQUIRED_ABSOLUTE_SECONDS",
    }) as Promise<bigint>,
    clients.robinhoodPublic.readContract({
      address: config.eligibilityRegistry,
      abi: eligibilityRegistryAbi,
      functionName: "currentRoundId",
    }) as Promise<bigint>,
  ]);

  const nowSec = BigInt(Math.floor(Date.now() / 1000));
  const dueTokenIds = watchlist.dueForCheck(currentRoundId, nowSec, requiredAbsoluteSeconds);

  for (const tokenId of dueTokenIds) {
    // Re-read directly rather than trusting the watchlist's own
    // last-scanned value - closes the gap between "matured as of the last
    // trade-activity scan" and "matured right now", and catches a
    // last-second reset scanForTradeActivity hasn't observed yet (e.g. a
    // sell in the same block range not yet incorporated).
    const aboveThresholdSince = (await clients.robinhoodPublic.readContract({
      address: config.eligibilityRegistry,
      abi: eligibilityRegistryAbi,
      functionName: "aboveThresholdSince",
      args: [tokenId],
    })) as bigint;
    watchlist.recordThresholdRead(tokenId, aboveThresholdSince);

    if (aboveThresholdSince === 0n) continue; // reset since it was scheduled - no longer due
    if (nowSec - aboveThresholdSince < requiredAbsoluteSeconds) continue; // streak restarted more recently than expected

    const alreadyCandidate = (await clients.robinhoodPublic.readContract({
      address: config.eligibilityRegistry,
      abi: eligibilityRegistryAbi,
      functionName: "isCandidate",
      args: [currentRoundId, tokenId],
    })) as boolean;
    if (alreadyCandidate) {
      // Trade activity qualified it automatically since we last checked -
      // record it so it's excluded from dueForCheck for this round without
      // needing another qualify() call.
      watchlist.markQualifiedForRound(tokenId, currentRoundId);
      continue;
    }

    const lockKey = `qualify-token-${tokenId}`;
    if (await lock.isInFlight(lockKey, { robinhood: clients.robinhoodPublic, arbitrum: clients.arbitrumPublic })) {
      results.push({ acted: false, detail: `qualify for token ${tokenId} already in flight, skipping` });
      continue;
    }

    if (config.dryRun) {
      results.push({ acted: true, detail: `[dry-run] would call qualify(${tokenId})` });
      continue;
    }

    const txHash = await clients.robinhoodWallet.writeContract({
      address: config.eligibilityRegistry,
      abi: eligibilityRegistryAbi,
      functionName: "qualify",
      args: [tokenId],
      chain: clients.robinhoodWallet.chain,
      account: clients.robinhoodWallet.account!,
    });
    lock.acquire(lockKey, txHash, "robinhood");
    watchlist.markQualifiedForRound(tokenId, currentRoundId);
    results.push({ acted: true, detail: `qualify(${tokenId}) submitted: ${txHash}` });
  }

  if (results.length === 0 || results.every((r) => !r.acted)) {
    results.push({
      acted: false,
      detail: `no tokens due for qualification this poll (watchlist: ${watchlist.size} known, ${watchlist.activeStreakCount} with an active streak, ${dueTokenIds.length} due)`,
    });
  }
  return results;
}
