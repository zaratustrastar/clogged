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
 * Detection is fully read-only, no guessing: aboveThresholdSince(tokenId)
 * (0 if not currently above threshold, else the timestamp the current
 * streak began) plus requiredAbsoluteSeconds (immutable, read once) tells
 * us definitively whether a token has matured. isCandidate() confirms it
 * isn't already qualified for the current round before spending gas.
 *
 * NEVER brute-forces the full tokenId space (see tokenWatchlist.ts): which
 * tokenIds to even consider comes from `watchlist`, built from real
 * TokenRegistered event history at startup and refreshed incrementally -
 * not from looping 1..nextTokenId-1. Only tokens the watchlist reports as
 * not-yet-qualified-for-the-current-round are read here at all.
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

  const [requiredAbsoluteSeconds, currentRoundId] = await Promise.all([
    clients.robinhoodPublic.readContract({
      address: config.eligibilityRegistry,
      abi: eligibilityRegistryAbi,
      functionName: "requiredAbsoluteSeconds",
    }) as Promise<bigint>,
    clients.robinhoodPublic.readContract({
      address: config.eligibilityRegistry,
      abi: eligibilityRegistryAbi,
      functionName: "currentRoundId",
    }) as Promise<bigint>,
  ]);

  const nowSec = BigInt(Math.floor(Date.now() / 1000));
  const candidateTokenIds = watchlist.tokensToCheck(currentRoundId);

  for (const tokenId of candidateTokenIds) {
    const aboveThresholdSince = (await clients.robinhoodPublic.readContract({
      address: config.eligibilityRegistry,
      abi: eligibilityRegistryAbi,
      functionName: "aboveThresholdSince",
      args: [tokenId],
    })) as bigint;

    if (aboveThresholdSince === 0n) continue; // not currently above threshold at all
    if (nowSec - aboveThresholdSince < requiredAbsoluteSeconds) continue; // hasn't matured yet

    const alreadyCandidate = (await clients.robinhoodPublic.readContract({
      address: config.eligibilityRegistry,
      abi: eligibilityRegistryAbi,
      functionName: "isCandidate",
      args: [currentRoundId, tokenId],
    })) as boolean;
    if (alreadyCandidate) {
      // Trade activity qualified it automatically since we last checked -
      // record it so the watchlist stops re-reading this token for this
      // round without needing another qualify() call.
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

  if (results.length === 0) {
    results.push({ acted: false, detail: `no matured, not-yet-candidate tokens found (watchlist size: ${watchlist.size})` });
  }
  return results;
}
