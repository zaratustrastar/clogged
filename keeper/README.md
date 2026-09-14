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
    config = loadConfig()              # throws if deploymentBlock unset, any address is zero, or KEEPER_PRIVATE_KEY missing
    watchlist = TokenWatchlist.build(from config.deploymentBlock)   # ONE full event scan, never repeated

loop:
    # 1. close due rounds
    if now >= currentRoundOpenTime + roundDuration:
        if not lock.inFlight("close-round-{id}"):
            closeRoundAndOpenNext()

    # 2. qualify matured tokens (watchlist-driven, not brute-forced)
    watchlist.scanForNewTokens()       # incremental only - new blocks since last scan
    for tokenId in watchlist.tokensToCheck(currentRoundId):   # excludes already-qualified-this-round
        since = aboveThresholdSince(tokenId)
        if since == 0: continue                                 # never above threshold / reset
        if now - since < requiredAbsoluteSeconds: continue        # not mature yet
        if isCandidate(currentRoundId, tokenId):
            watchlist.markQualifiedForRound(tokenId, currentRoundId); continue
        if not lock.inFlight("qualify-token-{tokenId}"):
            qualify(tokenId)
            watchlist.markQualifiedForRound(tokenId, currentRoundId)

    # 3. retry failed randomness requests (last 20 rounds)
    for roundId in [currentRoundId - 20 .. currentRoundId - 1]:
        r = getRound(roundId)
        if not r.closed or r.drawSkipped or r.randomnessRequested or r.settled: continue
        if not lock.inFlight("retry-randomness-round-{roundId}"):
            requestRandomnessForRound(roundId)

    # 4. relay fulfilled VRF results (last 20 rounds)
    for roundId in [currentRoundId - 20 .. currentRoundId - 1]:
        r = getRound(roundId)
        if not r.randomnessRequested or r.settled: continue
        f = VRFWrapperOnArbitrum.fulfilledRequests(r.randomnessRequestId)   # on ARBITRUM
        if not f.fulfilled or f.relayed: continue
        if not lock.inFlight("relay-randomness-request-{requestId}"):
            relayRandomness(requestId)                                      # on ARBITRUM

    # 5. observe settlement (read-only, never a transaction)
    for roundId in [currentRoundId - 20 .. currentRoundId - 1]:
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

## Token watchlist - never brute-forces the tokenId space

`qualifyMaturedTokens` does NOT read `nextTokenId` and loop over every
possible tokenId (which would mean up to 7,777 RPC calls every poll at the
protocol's ticker cap). Instead, `TokenWatchlist`:

1. At startup, does exactly ONE `getContractEvents` scan for
   `TokenRegistered`, from the manifest's verified `deploymentBlock` to the
   current block - reconstructing the real, current set of registered
   tokenIds from actual chain history, not a guess.
2. On each poll, does one cheap incremental scan (only the block range
   since the previous check) to pick up newly-registered tokens.
3. Tracks, per tokenId, which round it has already been confirmed
   qualified for - once qualified for the current round, a token is
   excluded from `tokensToCheck()` entirely until a new round opens. In
   steady state, the set of tokens actually re-examined every poll is only
   the ones NOT yet qualified for whichever round is currently open - a
   small, bounded number regardless of how many thousands of tokens have
   been launched historically.

See `test/actions/qualifyTokens.test.ts`'s own "never brute-forces" test,
which asserts `nextTokenId` is never even read.

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

```bash
npm run build
KEEPER_PRIVATE_KEY=0x<a fresh keypair's private key> npm run dry-run
```

Or directly: `node dist/index.js --dry-run`. In dry-run mode: every read
happens normally, every decision is made normally and logged, but no
transaction is ever sent and no lock file entry is ever written for a
dry-run "action". Runs exactly one pass and exits.

**Dry-run cannot currently produce a normal, non-error pass** - the real
tracked manifest's `deploymentBlock` is still `null` (pending
`scripts/verify-deployment.sh`'s real output - see the parent branch,
`canary-validation`), and `loadConfig()` deliberately refuses to start
until it's set, exactly as it should. Once that fix lands and this branch
rebases/merges the updated `canary-validation`, the same `--dry-run`
command above will run a real pass against live chain state (still
sending zero transactions).

## systemd

`systemd/clog-keeper.service` - see the file's own header for the full
install procedure. Runs as a dedicated `clog-keeper` system user (not
`clog`, not root), reads secrets from `/etc/clog-keeper/keeper.env`
(outside the git-tracked tree), and is deliberately **not installed,
enabled, or started by this commit**.

## Not yet deployed

This entire `keeper/` directory exists only on the `keeper-automation`
branch, has never been pushed, and has never been run against a real
private key, real funds, or real RPC access from the environment that
prepared it (same network-access limitation noted on the
`canary-validation` branch's own work - no path to
`rpc.mainnet.chain.robinhood.com` or `arb1.arbitrum.io` from this
sandbox). Every test here uses a mocked client or a fake, hardcoded test
private key. Do not enable the systemd service, do not fund the keeper
EOA, and do not merge this branch until an operator has reviewed the diff
and run a real `--dry-run` pass against live chain state first.
