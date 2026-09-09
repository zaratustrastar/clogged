# CLOG — MAINNET Deployment Guide (Canary)

Target: **Robinhood Chain MAINNET** (chain id 4663) + **Arbitrum ONE mainnet**.

This is not a testnet exercise. Every address and transaction below is real
once broadcast. The goal of this deployment is a small, deliberate canary —
deploy the real immutable system, test it end to end with small real
amounts, then scale up — not an immediate public launch.

**This guide does not broadcast anything.** Every command below omits
`--broadcast` deliberately; the equivalent broadcast commands are given
separately at the end, for you to run only when you're ready.

## Status of this guide

I could not independently resolve several required Chainlink infrastructure
values (see "Values I could not verify" below) — I have no web search tool
in this session, and confirmed directly that this environment's own network
egress does not reach Chainlink's documentation domains, nor the Robinhood
mainnet RPC/explorer URLs you supplied (all return 403 host_not_allowed
from this sandbox's own proxy — the error message itself suggests these
hosts could be added to network egress settings if you have access to that
configuration). I have not fabricated any router address, chain selector, or
key hash. Everything else below — env var names, script behavior, the VRF
payment currency, deployment order, and commands — is either read directly
from the actual script/contract source or is standard cast/forge tooling,
not guessed.

---

## 1. Confirmed network details (as you supplied them)

**Robinhood Chain Mainnet:**
- Chain ID: 4663
- Public RPC: https://rpc.mainnet.chain.robinhood.com
- Explorer: https://robinhoodchain.blockscout.com

Per your instruction: use this public RPC for deployment/read verification
now; do not wire it into the eventual production keeper/frontend if a
managed Robinhood endpoint becomes available.

I was not able to reach either URL from this environment to independently
confirm chain id 4663 responds at that RPC, or that the explorer is live —
both are blocked by this sandbox's own network egress, the same restriction
that blocks Chainlink's docs. Worth a quick manual check
(cast chain-id --rpc-url https://rpc.mainnet.chain.robinhood.com, see
section 3) before relying on it for real.

**Arbitrum One mainnet:** standard, long-established chain (id 42161) — not
something I'm treating as in question, only the specific Chainlink
infrastructure addresses on it (see section 2).

## 2. Values I could not verify — resolve these yourself, do not guess

**Robinhood Chain Mainnet:**
- CCIP_ROUTER_ROBINHOOD — CCIP Router address on Robinhood Chain Mainnet.
- ARBITRUM_CHAIN_SELECTOR — Arbitrum One's CCIP chain selector, as listed
  against Robinhood Chain Mainnet's own CCIP Directory entry.

**Arbitrum One mainnet:**
- CCIP_ROUTER_ARBITRUM — CCIP Router address on Arbitrum One.
- ROBINHOOD_CHAIN_SELECTOR — Robinhood Chain Mainnet's own CCIP chain
  selector, as listed in the directory.
- VRF_COORDINATOR_ARBITRUM — Chainlink VRF v2.5 Coordinator address on
  Arbitrum One.
- VRF_KEY_HASH — the VRF v2.5 key hash (gas lane) for Arbitrum One.

**The most important open question, explicitly**: does CCIP support BOTH
directions — Robinhood Mainnet -> Arbitrum One (needed for
ChainlinkRandomnessProvider.requestRandomness) AND Arbitrum One ->
Robinhood Mainnet (needed for VRFWrapperOnArbitrum.relayRandomness)? A lane
existing one way does not imply it exists the other way. Check Robinhood
Chain Mainnet's own CCIP Directory entry for an outbound lane to Arbitrum
One, and separately check whether Arbitrum One's entry lists an outbound
lane back to Robinhood Chain Mainnet. If only one direction exists, this
architecture cannot work as designed and that is a real blocker to surface
before deploying anything, not something to work around.

Check directly at https://docs.chain.link/ccip/directory (Robinhood Chain
Mainnet may or may not have an entry at all - this has not been confirmed)
and https://docs.chain.link/vrf/v2-5/supported-networks for the VRF values,
or ask me again in a session with search enabled.

## 3. Onchain verification (run these yourself — I cannot reach these RPCs)

Once you have real values for the addresses/selectors above, run these cast
commands before broadcasting anything. I've written them exactly as I would
run them if this environment could reach the RPCs — it can't (same network
restriction as section 1), so these are for you to run directly.

    # Non-empty bytecode at both CCIP Routers
    cast code $CCIP_ROUTER_ROBINHOOD --rpc-url $ROBINHOOD_MAINNET_RPC_URL
    cast code $CCIP_ROUTER_ARBITRUM --rpc-url $ARBITRUM_ONE_RPC_URL

    # Non-empty bytecode at the VRF Coordinator
    cast code $VRF_COORDINATOR_ARBITRUM --rpc-url $ARBITRUM_ONE_RPC_URL

    # Robinhood Router recognizes Arbitrum One as a destination -- the exact
    # call depends on the router's ABI (isChainSupported(uint64) on many
    # Chainlink CCIP router versions; confirm against the actual deployed
    # router's interface, since this varies by CCIP version):
    cast call $CCIP_ROUTER_ROBINHOOD "isChainSupported(uint64)(bool)" $ARBITRUM_CHAIN_SELECTOR --rpc-url $ROBINHOOD_MAINNET_RPC_URL

    # Arbitrum One Router recognizes Robinhood Mainnet as a destination (the
    # reverse-direction check -- do not skip this one):
    cast call $CCIP_ROUTER_ARBITRUM "isChainSupported(uint64)(bool)" $ROBINHOOD_CHAIN_SELECTOR --rpc-url $ARBITRUM_ONE_RPC_URL

    # Sanity-check your own RPC before relying on it
    cast chain-id --rpc-url $ROBINHOOD_MAINNET_RPC_URL   # expect 4663
    cast chain-id --rpc-url $ARBITRUM_ONE_RPC_URL         # expect 42161

For getFee() in both directions, the cleanest real check is deploying both
contracts first (steps 1-2 in section 5, without --broadcast) and letting
their own constructors/first calls exercise getFee naturally, since building
a correctly-shaped EVM2AnyMessage by hand outside the contracts themselves
risks testing something subtly different from what the real contracts will
actually send. If you want an isolated pre-deployment check anyway, cast
call against the router's getFee(uint64,(bytes,bytes,(address,uint256)[],address,bytes))
function needs a fully-encoded message struct matching whichever CCIP
version these routers run — worth confirming the exact function signature
from the router's own verified source on the explorer first, since this has
changed across CCIP versions.

**Do not broadcast anything in section 5 until every check above passes.**

## 4. VRF subscription — what you need to create

Confirmed directly from the actual contract source (VRFWrapperOnArbitrum.sol,
nativePayment: false in its VRF request extra-args) — this is not something
I looked up externally, it's how the contract you're about to deploy is
actually written, and changing it would require a Solidity edit that's
explicitly out of scope right now:

- The wrapper pays for VRF requests via the subscription's LINK balance,
  not native ETH. You need to fund the subscription with real LINK on
  Arbitrum One, not ETH.
- Separately, VRFWrapperOnArbitrum's own ETH balance is needed for a
  completely different purpose — the CCIP return relay fee
  (relayRandomness's outbound message back to Robinhood Chain). This is
  native ETH, paid directly by the wrapper contract, unrelated to the VRF
  subscription's LINK balance. Both need to be funded; neither substitutes
  for the other.
- Consumer address: once DeployArbitrumWrapper.s.sol has run and you have
  the real VRFWrapperOnArbitrum address, add that address as a consumer on
  your VRF v2.5 subscription — via Chainlink's subscription manager UI, or
  vrfCoordinator.addConsumer(subscriptionId, wrapperAddress) directly. Do
  this before the wrapper's first real request, or requests will revert (an
  unregistered consumer is rejected by the Coordinator itself).

I am not inventing a subscription ID anywhere in this guide or the env
template — VRF_SUBSCRIPTION_ID is left blank for you to fill in once you've
created the real one.

## 5. Deployment order

Run in exactly this order.

### Step 1 — DeployRobinhoodChain.s.sol (Robinhood Chain Mainnet)

Deploys EligibilityRegistry, RoundManager, RewardVault, TickerNFT,
TickerRegistry, ChainlinkRandomnessProvider, and the TimelockController that
becomes governance for everything — permanently, with no transfer path.
Needs: CCIP_ROUTER_ROBINHOOD, ARBITRUM_CHAIN_SELECTOR, SAFE_ADDRESS,
FEE_MULTISIG_ADDRESS, TICKER_NFT_BASE_URI.

Dry run:

    forge script script/DeployRobinhoodChain.s.sol \
      --rpc-url $ROBINHOOD_MAINNET_RPC_URL \
      --sig "run()"

Broadcast (only once section 3's checks pass and you're actually ready):

    forge script script/DeployRobinhoodChain.s.sol \
      --rpc-url $ROBINHOOD_MAINNET_RPC_URL \
      --broadcast \
      --sig "run()"

Read the logged output for the 7 deployed addresses and the two required
governance actions it prints — you'll need the ChainlinkRandomnessProvider
address in step 3.

### Step 2 — DeployArbitrumWrapper.s.sol (Arbitrum One mainnet)

Deploys VRFWrapperOnArbitrum and proposes ownership to
ARBITRUM_GOVERNANCE_ADDRESS. Needs: VRF_COORDINATOR_ARBITRUM,
CCIP_ROUTER_ARBITRUM, ROBINHOOD_CHAIN_SELECTOR, VRF_KEY_HASH,
VRF_SUBSCRIPTION_ID, ARBITRUM_GOVERNANCE_ADDRESS.

Dry run:

    forge script script/DeployArbitrumWrapper.s.sol \
      --rpc-url $ARBITRUM_ONE_RPC_URL \
      --sig "run()"

Broadcast:

    forge script script/DeployArbitrumWrapper.s.sol \
      --rpc-url $ARBITRUM_ONE_RPC_URL \
      --broadcast \
      --sig "run()"

After broadcasting: arbitrumGovernance must call acceptOwnership()
(ConfirmedOwner's two-step transfer), and you must register this wrapper as
a VRF subscription consumer (section 4) before it can request randomness.

### Step 3 — WireCrossChain.s.sol (once per chain)

Deploys nothing — only checks real code exists at both addresses, then logs
the exact target + calldata for the two remaining governance actions
(ChainlinkRandomnessProvider.setWrapper, VRFWrapperOnArbitrum.setProvider).
Needs: CHAINLINK_RANDOMNESS_PROVIDER (from step 1), VRF_WRAPPER_ON_ARBITRUM
(from step 2). This script has no broadcast mode of its own — it never
sends a transaction, only reads and logs:

    forge script script/WireCrossChain.s.sol \
      --rpc-url $ROBINHOOD_MAINNET_RPC_URL \
      --sig "run()"

    forge script script/WireCrossChain.s.sol \
      --rpc-url $ARBITRUM_ONE_RPC_URL \
      --sig "run()"

### After all three: required governance actions

Every onlyGovernance function is behind the 48h timelock by design — no
bootstrap bypass, even for day-one wiring. Queue these through the Safe once
the real addresses exist:

1. RoundManager.setRewardVault(rewardVault) — on Robinhood Chain Mainnet.
2. ChainlinkRandomnessProvider.setWrapper(wrapperOnArbitrum) — on Robinhood
   Chain Mainnet.
3. VRFWrapperOnArbitrum.setProvider(providerOnRobinhoodChain) — on Arbitrum
   One, queued through whatever ARBITRUM_GOVERNANCE_ADDRESS actually is,
   not the Robinhood Chain timelock.

The protocol cannot resolve any draw until all three clear their delays and
execute.

## 6. Canary approach — no protocol parameter changes

Per your instruction, this deployment uses the real, unmodified production
economics — LAUNCH_PRICE (0.002 ETH), the 0.5% trade tax and its 20/10/70
split, the 5% progress gate, the 0.229 ETH reserve threshold, the 30-minute
timer, MIN_DRAW_CANDIDATES = 3, the 1-hour round duration — none of these
are being loosened or tightened for testing purposes, since they're not
meant to be test-only values and changing them would misrepresent the
system you're actually canary-testing. "Small real amounts" means launching
a small number of memes and trading small ETH amounts against the real,
unmodified contracts — not changing the contracts' own thresholds to make
testing easier.

## 7. Ongoing funding (not one-time)

Two ETH balances need to stay funded for draws to keep resolving, plus the
separate LINK requirement from section 4:

- ChainlinkRandomnessProvider's ETH balance (Robinhood Chain Mainnet) —
  pays the outbound CCIP fee on every randomness request. If it runs dry,
  rounds still close and open on schedule — only the request itself fails
  and becomes retryable via requestRandomnessForRound() once topped up.
- VRFWrapperOnArbitrum's ETH balance (Arbitrum One) — pays the return CCIP
  fee on every relayRandomness() call. If it runs dry, the fulfilled word is
  still safely stored — only the relay fails and becomes retryable via
  relayRandomness() once topped up.
- The VRF subscription's LINK balance (Arbitrum One) — entirely separate
  from the wrapper's own ETH balance above (section 4).

No specific amounts are prescribed anywhere in this guide — they depend on
live CCIP fee pricing at request/relay time, which isn't knowable in
advance. For a canary deployment, fund modestly and monitor rather than
over-provisioning.
