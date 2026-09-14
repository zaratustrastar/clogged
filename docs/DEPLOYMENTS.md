# Deployment manifest — why it's tracked in git

## The problem this solves

Before this, the five protocol contract addresses, the chain id, and the
deployment block all came from `NEXT_PUBLIC_*` variables in
`/opt/clogged/.env.production` on the VPS — a file that is deliberately
**not** committed (see `.gitignore`) and **not** touched by `git pull`.

That meant switching deployments (e.g. from an old deployment to a new one)
required editing `.env.production` directly on the server, by hand, every
time. If that step was ever missed or done against the wrong deployment, a
stale address would keep serving silently — `git pull` alone could never
fix it, because `git pull` never touches that file.

## The fix

`deployments/robinhood-mainnet.json` is a small, tracked, public JSON file
containing only:

- `chainId`
- `deploymentBlock`
- `contracts.tickerRegistry` / `tickerNFT` / `eligibilityRegistry` /
  `roundManager` / `rewardVault` — the five addresses the frontend actually
  reads (see `POST_DEPLOY_HANDOFF.md`)

`lib/web3/env.ts` imports this file directly (`import deploymentManifest
from "@/deployments/robinhood-mainnet.json"`) and uses it as the **only**
source for those seven values. The corresponding `NEXT_PUBLIC_*` variables
(`NEXT_PUBLIC_ROBINHOOD_CHAIN_ID`, `NEXT_PUBLIC_DEPLOYMENT_BLOCK`,
`NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS`, etc.) are no longer read from
`process.env` anywhere in the codebase — `lib/web3/env.test.ts` asserts this
directly (`env.ts`'s source text must never contain
`process.env.NEXT_PUBLIC_TICKER_REGISTRY_ADDRESS` or any of its six
siblings) so this can't silently regress.

**Practical effect:** an old `/opt/clogged/.env.production` with leftover
values for any of those seven variables is simply inert for them — they are
never consulted. Switching deployments is now: edit
`deployments/robinhood-mainnet.json`, commit, `git pull` on the VPS,
rebuild. Nothing else.

## What stays in `.env.production` (never moves here)

Everything secret, server-specific, or genuinely operator-choice stays an
environment variable, exactly as before:

- `DATABASE_URL`, upload directory/base URL — server-only, never
  `NEXT_PUBLIC_*`, never committed
- `NEXT_PUBLIC_REOWN_PROJECT_ID` — a per-deployment API credential, not part
  of "which contracts is the app pointed at"
- `NEXT_PUBLIC_ROBINHOOD_RPC_URL` / `NEXT_PUBLIC_ROBINHOOD_EXPLORER_URL` — an
  operator might reasonably swap the public RPC for a dedicated provider
  (Alchemy, QuickNode) without that being a "deployment" change at all
- `NEXT_PUBLIC_APP_URL`, the v4 trading addresses/flag — genuinely
  independent of which core protocol deployment is active

Nothing in `deployments/*.json` is ever a secret. No private key, database
credential, or signer credential belongs in this directory, ever — see the
file's own `$comment` field.

## One source of truth

`lib/web3/addresses.ts` re-exports `env.tickerRegistry` etc. unchanged — it
never reads the manifest or `process.env` directly. `lib/web3/deployments.ts`'s
`getActiveDeployment()` reads `env.chainId`/`env.tickerRegistry` — also
unchanged. No component, hook, or API route hardcodes a contract address or
imports the manifest directly; everything goes through `env.ts`. This was
already true before this change and remains true after it — only *where*
`env.ts` itself sources these seven values changed.

## Verifying a manifest before trusting it

`deployments/robinhood-mainnet.json` records addresses as configuration —
whoever edits it is asserting these are correct, not proving it. The
deployed system spans two chains (Robinhood Chain and Arbitrum One, via the
Chainlink CCIP/VRF randomness path), so verification has to cover both, not
just the five frontend addresses. `scripts/verify-deployment.sh` is the
actual proof: a read-only script (only `cast call`/`cast code`/`cast
block-number`/`cast chain-id` — never sends a transaction, never needs a
private key, on either chain) that:

1. Confirms real contract code exists at every address on both chains: the
   five Robinhood Chain contracts plus `ChainlinkRandomnessProvider`, and
   the `VRFWrapperOnArbitrum` on Arbitrum One.
2. Confirms every cross-contract getter each contract actually exposes
   points at exactly what the manifest claims — on Robinhood Chain:
   `TickerRegistry.eligibilityRegistry()`, `.tickerNFT()`, `.winnerPot()`
   (which is the RewardVault address — see `TickerRegistry.sol`'s own
   constructor), `TickerNFT.tickerRegistry()`, `RoundManager.engine()`,
   `.randomnessProvider()`, `.rewardVault()`, `RewardVault.roundManager()`,
   `EligibilityRegistry.roundManager()`,
   `ChainlinkRandomnessProvider.roundManager()`, `.wrapperOnArbitrum()` —
   and the cross-chain half, on Arbitrum One:
   `VRFWrapperOnArbitrum.providerOnRobinhoodChain()` (must point back at
   the Robinhood-side provider), plus `.subscriptionId()` and `.keyHash()`
   matching the deployed canary's real Chainlink VRF subscription
   configuration. This is what catches an address (or VRF config value)
   accidentally swapped or mismatched in the manifest, which "code exists"
   alone would never catch.
3. Determines the real deployment block via binary search on
   `TickerRegistry`'s own code presence across Robinhood Chain's block
   history — never assumed to be "whatever the current block happens to
   be" and never otherwise guessed.

Run it wherever there is real RPC access to both chains (this repository's
own sandboxed preparation environment has neither — see the PR/commit this
file shipped in for that caveat stated up front). Fill in
`deploymentBlock` in the manifest from the script's own output, re-run
until it reports zero failures, and only then point `clog.run` at it.
