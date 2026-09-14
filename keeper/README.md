# CLOG keeper

A minimal, permissionless automation service for the CLOG protocol. It
closes due rounds, qualifies matured tokens, retries failed randomness
requests, relays fulfilled VRF results from Arbitrum to Robinhood Chain,
and reports settlement/funding status.

**Not yet deployed or enabled.** See "Not yet deployed" at the bottom.

## Architecture

```
keeper/
  src/
    config.ts           - reads deployments/robinhood-mainnet.json + env, validates, refuses to start incomplete
    clients.ts           - viem public/wallet clients for both chains, one dedicated keeper EOA
    logger.ts            - structured JSON-lines logging
    retry.ts              - exponential-backoff retry for transient RPC failures
    lock.ts                - file-based idempotency lock (in-flight-transaction guard)
    tokenWatchlist.ts       - event-reconstructed token set, never brute-forces the tokenId space
    index.ts                - the decision loop, graceful shutdown
    abis/                    - ABIs regenerated directly from contract source (forge inspect)
    actions/
      closeRounds.ts          - close due rounds
      qualifyTokens.ts         - qualify matured tokens (watchlist-driven)
      retryRandomness.ts        - retry failed randomness requests
      relayRandomness.ts         - relay fulfilled VRF results (Arbitrum -> Robinhood)
      observeSettlement.ts        - read-only settlement monitoring
      fundingHealth.ts             - read-only balance/funding warnings
  test/                            - decision-path tests per action, plus config/lock tests
  systemd/clog-keeper.service       - systemd unit (not installed by this commit)
  .env.example                       - env var template, no secrets
```

Addresses, chain id, and deployment block come from the SAME tracked
`../deployments/robinhood-mainnet.json` manifest the frontend uses - one
source of truth. The keeper adds one field to that manifest's own
`$notReadByFrontend` block, `arbitrumVrfCoordinator` - a **public** VRF
coordinator contract address (not a secret, not a frontend concern),
needed only for the funding-health VRF subscription balance check.

## Decision loop (pseudocode)

Run once per poll interval (default 30s), or once and exit under
`--dry-run` / `KEEPER_RUN_ONCE=true`:

```
on startup:
    config = loadConfig()              # throws if deploymentBlock unset or any address is zero; also throws on missing KEEPER_PRIVATE_KEY in normal (non-dry-run) mode only - see the --dry-run section below
    watchlist = TokenWatchlist.build(from config.deploymentBlock)   # ONE full event scan, never repeated

loop:
    # 1. close due rounds
    if now >= currentRoundOpenTime + roundDuration:
        if not lock.inFlight("close-round-{id}"):
            closeRoundAndOpenNext()

    # 2. qualify matured tokens (small active-set watchlist, event-driven)
    watchlist.scanForNewTokens()       # incremental - new TokenRegistered events only, seeds each new token's initial aboveThresholdSince
    watchlist.scanForTradeActivity()   # incremental - ONE getLogs call across ALL known markets for Bought+Sold, re-reads aboveThresholdSince ONLY for tokens that actually traded
    for tokenId in watchlist.dueForCheck(currentRoundId, now, requiredAbsoluteSeconds):  # active-streak AND scheduled-maturity-time-passed AND not-yet-qualified-this-round
        since = aboveThresholdSince(tokenId)      # re-confirm directly before spending gas
        watchlist.recordThresholdRead(tokenId, since)
        if since == 0: continue                     # reset since it was scheduled
        if now - since < requiredAbsoluteSeconds: continue
        if isCandidate(currentRoundId, tokenId):
            watchlist.markQualifiedForRound(tokenId, currentRoundId); continue
        if not lock.inFlight("qualify-token-{tokenId}"):
            qualify(tokenId)
            watchlist.markQualifiedForRound(tokenId, currentRoundId)

    ledger.scanForNewEvents()   # incremental - shared by steps 3, 4, 5 below (one scan, not three)

    # 3. retry failed randomness requests - NO fixed lookback: every closed,
    #    drawable, unrequested round the ledger has ever seen is due, no
    #    matter how long ago it closed
    for roundId in ledger.needsRandomnessRetry():
        if not lock.inFlight("retry-randomness-round-{roundId}"):
            requestRandomnessForRound(roundId)

    # 4. relay fulfilled VRF results - NO fixed lookback, same reasoning
    for (roundId, requestId) in ledger.needsRelayCheck():
        f = VRFWrapperOnArbitrum.fulfilledRequests(requestId)   # on ARBITRUM
        if not f.fulfilled or f.relayed: continue
        if not lock.inFlight("relay-randomness-request-{requestId}"):
            relayRandomness(requestId)                            # on ARBITRUM

    # 5. observe settlement (read-only, never a transaction) - NO fixed lookback
    for roundId in ledger.outstandingRequested():
        log round's settled/winner/stuck-warning status

    # 6. funding health (read-only, never a transaction, never auto-funds)
    log ETH balances of: ChainlinkRandomnessProvider, VRFWrapperOnArbitrum, keeper EOA (both chains)
    log VRF subscription LINK + native balance
    warn if any below threshold
```

Every step is independently wrapped in retry-with-backoff (transient RPC
failures only - a contract revert is the correct answer, not retried) and
a try/catch, so one step's failure never blocks the others.

## Why every action is safe: permissionless by contract design

Every state-changing call the keeper ever makes has been confirmed,
directly against the deployed contract source (not assumed), to be
`external` with **no access modifier**:

| Function | Contract | Confirmed via |
|---|---|---|
| `closeRoundAndOpenNext()` | RoundManager | source read, no modifier |
| `qualify(tokenId)` | EligibilityRegistry | source read + doc comment: "anyone" |
| `requestRandomnessForRound(roundId)` | RoundManager | source read + doc comment: "Permissionless retry" |
| `relayRandomness(requestId)` | VRFWrapperOnArbitrum | source read + doc comment: "Permissionless" |

`onRandomnessReceived` (the function that actually marks a round settled)
is the opposite - restricted to `msg.sender == address(randomnessProvider)`
- confirmed directly too. The keeper never calls it and never could; that
step happens automatically once CCIP delivers the relayed message. This is
exactly why "observe settlement" is read-only, not an action.

## Security assumptions

- **Dedicated keeper EOA, never the deployer/Safe/governance wallet.**
  Because every action above is permissionless, the keeper key needs zero
  elevated permission on either chain - it is a plain EOA whose only
  capability is "can pay gas and call these four fixed functions". Losing
  this key costs at most its own ETH balance; it can never move protocol
  funds, never change governance, never touch a contract it isn't already
  allowed to touch as anyone.
- **No automatic funding in v1.** `fundingHealth` only ever reads balances
  and logs warnings - it never sends ETH anywhere, on either chain, under
  any condition. An operator (or their own external alerting watching
  these structured log lines) funds manually.
- **Idempotency is defense in depth, not the primary safety mechanism.**
  Every action the keeper calls is ALSO idempotent at the contract level
  (see each action file's own doc comment for the specific `require()` that
  makes double-execution impossible) - the file-based lock exists only to
  avoid wasting gas on redundant in-flight transactions during a short poll
  interval, not to prevent an actual double-spend or double-action, which
  the contracts themselves already prevent.
- **Never modifies smart contracts.** This is a pure off-chain automation
  client calling existing, already-verified contract functions.
- **Not yet run against a real private key or real funds.** Every test in
  this repository uses a fake, hardcoded test key and a mocked RPC client -
  see "Not yet deployed" below.

## Token watchlist - a genuinely small active set, not brute force

`qualifyMaturedTokens` never reads `nextTokenId` and loops over every
possible tokenId. It also does NOT merely re-check "every launched token
except the ones already qualified this round" - an earlier version of this
class did exactly that, which is not actually small once the protocol
approaches its 7,777-ticker cap (most launched tokens are never mature at
any given moment, so re-reading `aboveThresholdSince` for all of them every
poll scales with total tokens ever launched, not with real activity).

`EligibilityRegistry` does not emit an event when a token's
`aboveThresholdSince` starts or resets (confirmed directly against its
source - it emits only `TokenRegistered`, `Qualified`, `RoundOpened`,
`RoundManagerInitialized`), so there is no direct way to learn "this
token's streak just changed" from an `EligibilityRegistry` event alone.
What IS observable is trade activity on each token's own market:
`EligibilityRegistry.onTrade()` (which drives `aboveThresholdSince`) is
called by the market contract on every buy/sell, and `BondingCurveClog`
itself emits real `Bought`/`Sold` events - one stream per market. Rather
than filtering by every known market address (which risks an
undocumented provider limit on address-array size once thousands of
markets exist - real RPC providers vary, and none of that is ours to
assume), this queries the `Bought`/`Sold` event **topics directly with no
address filter at all** - `eth_getLogs`'s topic match is an exact,
RPC-side comparison against the full 32-byte event-signature hash, so the
query costs exactly the same (2 calls, one per event) whether 1 or 7,777
markets exist. `tokenId` is
never inferred from the `Bought`/`Sold` event's own fields (neither event
carries one) - it comes from the log's own emitting contract address,
matched locally against a `market -> tokenId` map built once from
`TokenRegistered`'s own `(tokenId, market)` pair - a log from any other
address (routine and expected with no address filter applied) is simply
skipped.

**RPC calls per poll:** exactly 2, regardless of market count.
**Maximum request size:** bounded only by the block range scanned (new
blocks since last poll), never by market count. **Worst case at 7,777
markets:** unchanged - still exactly 2 calls; only the number of
*results* can grow with real trading volume, never the request itself.
**During high trading activity:** more logs come back in the same 2
calls - never more calls, never a larger request.

1. **Startup (once):** scan `TokenRegistered` (deploymentBlock -> latest)
   for every known tokenId + market address, then one `aboveThresholdSince`
   read per known token to seed the active-streak set. Both are real,
   bounded, one-time costs - not repeated every poll.
2. **Every poll (cheap):** one incremental `TokenRegistered` scan (new
   blocks only; any newly-launched token gets its own one-time seed read);
   one `eth_getLogs` call across every known market address for
   `Bought`+`Sold` (new blocks only) - resolves to a small set of tokenIds
   that actually traded; `aboveThresholdSince` is re-read ONLY for that
   small traded set, updating or removing them from the active-streak set
   based on the real, current value.
3. **`dueForCheck()`:** only active-streak tokens (nonzero
   `aboveThresholdSince`) whose scheduled maturity time
   (`aboveThresholdSince + requiredAbsoluteSeconds`) has already passed,
   and that are not already marked qualified for the current round. This -
   not the full active-streak set, and never the full watchlist - is what
   `qualifyMaturedTokens` actually re-reads `isCandidate()`/calls
   `qualify()` for.

**Result:** per-poll RPC reads scale with real trading activity and how
many streaks are concurrently maturing, never with total tokens ever
launched. See `test/actions/qualifyTokens.test.ts`'s "worst case at scale"
test: 500 known tokens, only 1 with an active streak - exactly one
`aboveThresholdSince` read happens, not 500.

## Round ledger - no fixed lookback horizon

`retryFailedRandomness`, `relayFulfilledRandomness`, and
`observeSettlement` never scan only "the last N rounds". An earlier
version of this keeper used a fixed 20-round lookback window in all
three - a round the keeper was offline long enough to miss (more than 20
rounds' worth of downtime) would have silently stopped being tracked
forever, even though `RoundManager` itself places no age limit on when
`requestRandomnessForRound`/`relayRandomness` remain callable (confirmed
directly against both contracts' source).

`RoundLedger` reconstructs outstanding work the same way `TokenWatchlist`
reconstructs the token set - from real event history, with no horizon:

- **Startup (once):** scan `RoundClosed`, `RandomnessRequested`, and
  `RoundSettled` (deploymentBlock -> latest) to reconstruct the exact
  real current state - which rounds are closed-but-unresolved, which
  have a real `requestId` awaiting relay, which are already settled. A
  bounded, one-time cost proportional to total rounds ever opened (set
  by the protocol's own round cadence, not by token/market count).
- **Every poll (cheap):** one incremental scan per event type - 3 total
  `getContractEvents` calls, but against `RoundManager`'s single fixed
  address, so no market-count-style scaling concern applies here at all.
  `RoundSettled` removes a round from every internal map entirely (not
  merely marks it done) - the ledger's own memory footprint is bounded by
  *outstanding* work, never by total rounds ever opened.
- `needsRandomnessRetry()` / `needsRelayCheck()` / `outstandingRequested()`
  are small, precomputed sets with no age limit built in anywhere - a
  round closed 10,000 rounds ago that's still unresolved is found and
  acted on exactly the same way as one closed a minute ago.

See `test/roundLedger.test.ts`'s own tests proving: many old outstanding
rounds are all returned at once with no cap; a settled round is removed
entirely, not merely skipped; and `RoundLedger.build` performs its scan
starting at the real `deploymentBlock`, never genesis or "now". See also
`test/actions/retryRandomness.test.ts` and `relayRandomness.test.ts`'s
own "restart reconstructs outstanding work correctly" tests, which
simulate a full process restart (a brand new ledger instance against the
same real event history) and confirm the identical outstanding work is
found again.

## Bounded block-range chunking (RPC provider limits)

Neither `TokenWatchlist`'s nor `RoundLedger`'s startup reconstruction
requests the entire `deploymentBlock -> latest` range in a single
`eth_getLogs` call, even though both need to see that entire range at
least once. Many real RPC providers cap the block range or log count a
single call may span/return - often undocumented, and different from
provider to provider - so an unbounded single call that works fine early
in the protocol's life eventually breaks as history grows, independent
of the address-count fix already applied to trade-event scanning.

`src/blockRangeChunker.ts`'s `scanBlockRangeInChunks` is the one shared
place both classes walk a block range in bounded pieces (configurable via
`KEEPER_LOG_CHUNK_BLOCKS`, default 2000 blocks) - contiguous,
non-overlapping chunks by construction (chunk N+1 always starts at chunk
N's end + 1), so every block in range is covered exactly once. The exact
same method serves both the large initial startup scan and every small
ordinary incremental poll - chunking an already-small range just produces
a single chunk, so there's no separate "small range" code path to keep in
sync.

See `test/blockRangeChunker.test.ts` for the chunker's own direct proofs
(no gap/duplicate at boundaries; chunked results equal one conceptual
full-range call), and the "chunked historical reconstruction" tests in
`test/tokenWatchlist.test.ts`/`test/roundLedger.test.ts` for the same
proof at the class level - a chunked reconstruction and a single-call
reconstruction of the identical fake history produce identical resulting
state, and a small-chunk-size restart still finds registrations/rounds
from the very start of a long history.

## Required keeper balances

Two separate ETH balances, on two separate chains, both funded manually
(never automatically):

- **Robinhood Chain**: the keeper EOA needs ETH for gas to call
  `closeRoundAndOpenNext`, `qualify`, and `requestRandomnessForRound`.
  Robinhood Chain's own documented gas costs are sub-cent per transaction
  under normal conditions.
- **Arbitrum One**: the keeper EOA needs ETH for gas to call
  `relayRandomness`.

Separately (not the keeper's own balance, but required for the pipeline
the keeper automates to function at all):

- **`ChainlinkRandomnessProvider`** (Robinhood Chain) needs its own ETH
  balance to pay the outbound CCIP fee when `requestRandomness` sends a
  message to Arbitrum.
- **`VRFWrapperOnArbitrum`** (Arbitrum One) needs its own ETH balance to
  pay the return CCIP fee when `relayRandomness` sends the fulfilled word
  back to Robinhood Chain.
- **The Chainlink VRF subscription** needs LINK (to pay for VRF requests)
  and may need a native-token balance depending on the subscription's
  payment configuration.

`fundingHealth` checks all of these every poll and logs a warning for any
that's low - it never funds any of them itself.

## Exact funding-health thresholds

- ETH balance warning: below `KEEPER_LOW_BALANCE_WARNING_WEI` (env,
  default `5000000000000000` wei = 0.005 ETH), checked independently for:
  `ChainlinkRandomnessProvider`, `VRFWrapperOnArbitrum`, and the keeper EOA
  on both chains (4 independent checks, same threshold).
- VRF subscription LINK balance warning: below `1000000000000000000`
  wei-LINK (1 LINK) - a conservative, simple v1 threshold, not a
  Chainlink-published minimum; tune based on real observed request
  frequency and LINK cost once the canary has real trading volume.
- VRF subscription native balance: logged for visibility, no warning
  threshold set yet in v1 (the subscription's own payment configuration
  determines whether this matters at all).

## Structured logs

Every log line is a single JSON object on stdout (info/warn) or stderr
(error): `{"ts", "level", "action", "message", ...extra fields}`. No
external logging library - systemd/journald captures stdout/stderr
natively, and any downstream aggregator can parse JSON lines without a
custom grammar.

## Retry/backoff

Every RPC-touching step is wrapped in `withRetry` (`src/retry.ts`):
up to 3 attempts, exponential backoff (500ms, 1s, 2s... capped at 8s) with
jitter, but ONLY for transient, network-shaped failures (connection
resets, timeouts, rate limits, 5xx) - a contract revert is the correct,
final answer for that poll cycle and is never retried.

## Graceful shutdown

`SIGTERM` (systemd's own default stop signal) and `SIGINT` (Ctrl+C) both
let the current loop iteration finish before exiting cleanly, rather than
being killed mid-transaction-submission. A second signal forces immediate
exit, in case a hung RPC call is preventing graceful completion.

## `--dry-run`

Genuinely read-only: creates no wallet signer and requires no signing
secret at all.

```bash
npm run build
node dist/index.js --dry-run
```

`KEEPER_PRIVATE_KEY` is never read in dry-run mode - not "read but
ignored", never read at all, even if it happens to be set in the
environment (e.g. testing on a machine where the real `.env` is also
present). `createClients` (`clients.ts`) creates no `viem` wallet client
or account at all when there's no private key; `robinhoodWallet`/
`arbitrumWallet` are a stub whose `writeContract` throws immediately if
ever called, so even a bug that skipped an action's own `if
(config.dryRun)` check can't send anything - see `test/clients.test.ts`.

Every read happens normally, every decision is made normally and logged,
but no transaction is ever sent and no lock file entry is ever written
for a dry-run "action". Runs exactly one pass and exits.

If you want `fundingHealth`'s own report to include the future keeper
EOA's balance while dry-running, set the optional, PUBLIC `KEEPER_ADDRESS`
env var (no secret required):

```bash
KEEPER_ADDRESS=0x<the address a real key would use> node dist/index.js --dry-run
```

Without either `KEEPER_PRIVATE_KEY` (normal mode) or `KEEPER_ADDRESS`
(dry-run), `fundingHealth` simply skips the keeper-EOA balance checks and
says so in its own log line - `ChainlinkRandomnessProvider`,
`VRFWrapperOnArbitrum`, and the VRF subscription's own funding are still
checked regardless, since none of those depend on the keeper EOA at all.

Normal (non-dry-run) operation is unchanged: `KEEPER_PRIVATE_KEY` is
still required, checked before anything else, exactly as before - see
`test/config.test.ts`'s own tests for both directions of this.

## systemd

`systemd/clog-keeper.service` - see the file's own header for the full
install procedure. Runs as a dedicated `clog-keeper` system user (not
`clog`, not root), reads secrets from `/etc/clog-keeper/keeper.env`
(outside the git-tracked tree), and is deliberately **not installed,
enabled, or started by this commit**.

## Not yet deployed

This `keeper/` directory lives on the `keeper-production-rollout` branch
(ported cleanly from `keeper-automation`, which itself carried unrelated
v4/canary-validation history - `keeper-production-rollout` starts from
the already-verified `canary-frontend-rollout` instead, so it inherits a
real, verified `deploymentBlock` with none of that unrelated baggage).
This branch has never been run against a real private key, real funds, or
real RPC access from the environment that prepared it (same network-
access limitation noted on the frontend rollout branches' own work - no
path to `rpc.mainnet.chain.robinhood.com` or `arb1.arbitrum.io` from this
sandbox). Every test here uses a mocked client or a fake, hardcoded test
private key. Do not enable the systemd service, do not create or fund the
keeper EOA, and do not merge this branch until an operator has reviewed
the diff and run a real `--dry-run` pass against live chain state first.
