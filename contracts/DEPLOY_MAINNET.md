# CLOG — MAINNET Deployment Runbook (Chainlink VRF v2.5 + CCIP)

Target: **Robinhood Chain Mainnet** (chain id 4663) + **Arbitrum One** (chain
id 42161). Randomness architecture: Chainlink VRF v2.5 + CCIP, as decided —
RH-VRF was evaluated and explicitly not adopted for this launch (see the
randomness investigation in project history; "INSUFFICIENT EVIDENCE — KEEP
CHAINLINK FOR NOW" stands until revisited after RH-VRF has more audit
history).

**Nothing in this document broadcasts a transaction.** Every dry-run command
below omits `--broadcast`. The equivalent broadcast commands are given
alongside each phase, clearly marked, for you to run yourself only when
ready — I will never run them, and this response does not run them either.

## What I could not verify from this environment

I have no web search tool and no network path to `rpc.mainnet.chain.robinhood.com`,
`robinhoodchain.blockscout.com`, or Chainlink's documentation domains in this
session (confirmed directly — all return `403 host_not_allowed` from this
sandbox's own network egress). Every address below marked "operator-supplied"
is exactly that — I have not independently confirmed it points at real,
correctly-configured infrastructure. **Phase A's `MainnetPreflight.s.sol`
run is what actually verifies this, and is not optional.**

## Operator-supplied configuration (verify via Phase A before trusting)

```
Robinhood Chain Mainnet:      chain id 4663
  RPC:                        https://rpc.mainnet.chain.robinhood.com
  Explorer:                   https://robinhoodchain.blockscout.com
  CCIP Router:                0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9
  CCIP selector:              6180753054346818345

Arbitrum One:                 chain id 42161
  CCIP Router:                0x141fa059441E0ca23ce184B6A78bafD2A517DdE8
  CCIP selector:              4949039107694359620
  VRF v2.5 Coordinator:       0x3C0Ca683b403E37668AE3DC4FB62F4B29B6f7a3e
  Intended keyHash:           0x8472ba59cf7134dfe321f4d61a430c4857e8b19cdd5230b09952a92671c24409

Permanent NFT base URI:       https://clog.run/api/ticker-metadata/
```

## Signer setup — encrypted keystore, never a raw key anywhere

Foundry's encrypted keystore is used for every command below instead of a
raw private key in an env var, a flag, or shell history. This is a one-time
setup per wallet:

```bash
# Prompts interactively for the private key (masked, never echoed) and a
# keystore password to encrypt it with. The private key is never accepted
# as a CLI argument here, so it can never appear in shell history or a
# process listing. Run once per wallet (you have two: Robinhood, Arbitrum).
cast wallet import clog-deployer-robinhood --interactive
cast wallet import clog-deployer-arbitrum --interactive
```

Every `forge script`/`cast send` command below that needs to sign uses
`--account clog-deployer-robinhood` or `--account clog-deployer-arbitrum`
(Foundry prompts for the keystore password at broadcast time, not before) —
never `--private-key`. If your deployment wallet is a hardware wallet
Foundry supports (Ledger/Trezor via `--ledger`/`--trezor`), that is strictly
preferable to even an encrypted keystore for a real mainnet deployment —
use it if available; the commands below show the keystore form since that's
guaranteed compatible with forge 1.8.1/cast 1.8.1 without assuming hardware
you may not have.

Verify the keystore resolves to the wallet you expect before doing anything
else:

```bash
cast wallet address --account clog-deployer-robinhood
cast wallet address --account clog-deployer-arbitrum
```

---

## PHASE A — Preflight (read-only, no broadcast)

Run `MainnetPreflight.s.sol` once per chain. It auto-detects which chain
it's on from `block.chainid` and runs the checks relevant to that side —
see the script's own doc comments for exactly what each check does and
which Chainlink interface it reads (nothing here is a guessed ABI; every
interface is read directly from the vendored `@chainlink/contracts`/
`@chainlink/contracts-ccip` packages this repo already depends on).

```bash
export CCIP_ROUTER_ROBINHOOD=0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9
export ARBITRUM_CHAIN_SELECTOR=4949039107694359620
export SAFE_ADDRESS=<your Robinhood Safe address>
export DEPLOYER_ADDRESS=$(cast wallet address --account clog-deployer-robinhood)

forge script script/MainnetPreflight.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --sig "run()"
```

```bash
export CCIP_ROUTER_ARBITRUM=0x141fa059441E0ca23ce184B6A78bafD2A517DdE8
export VRF_COORDINATOR_ARBITRUM=0x3C0Ca683b403E37668AE3DC4FB62F4B29B6f7a3e
export ROBINHOOD_CHAIN_SELECTOR=6180753054346818345
export ARBITRUM_GOVERNANCE_ADDRESS=<your Arbitrum governance address, if a Safe>
export DEPLOYER_ADDRESS=$(cast wallet address --account clog-deployer-arbitrum)
# VRF_SUBSCRIPTION_ID: leave unset for now if you haven't created it yet (Phase G) -
# the script explicitly skips that one check rather than failing when it's absent.

forge script script/MainnetPreflight.s.sol --rpc-url https://arb1.arbitrum.io/rpc --sig "run()"
```

**Do not proceed to Phase B until both runs pass with no `FAIL:` output.**
A `getFee() reverted` line is logged but does not fail the run by itself —
investigate it, but it's the one check documented as best-effort (see the
script's own comments for why).

---

## PHASE B — Robinhood Mainnet deployment

Deploys `EligibilityRegistry`, `RoundManager`, `RewardVault`, `TickerNFT`,
`TickerRegistry`, `ChainlinkRandomnessProvider`, and the `TimelockController`
that becomes `governance` — permanently, with no transfer path. Needs:
`CCIP_ROUTER_ROBINHOOD`, `ARBITRUM_CHAIN_SELECTOR`, `SAFE_ADDRESS`,
`FEE_MULTISIG_ADDRESS`, `TICKER_NFT_BASE_URI`.

```bash
export TICKER_NFT_BASE_URI=https://clog.run/api/ticker-metadata/
export FEE_MULTISIG_ADDRESS=<your fee multisig address>
```

Dry run:

```bash
forge script script/DeployRobinhoodChain.s.sol \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --sig "run()"
```

Broadcast (only after Phase A passes and you are actually ready):

```bash
forge script script/DeployRobinhoodChain.s.sol \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account clog-deployer-robinhood \
  --broadcast \
  --sig "run()"
```

---

## PHASE C — Record deployment block + addresses

From the script's logged output, record all seven, exactly as printed —
you will need every one of them in later phases and for the frontend
handoff:

```
Deployment block:            _______________
TimelockController:          _______________
EligibilityRegistry:         _______________
ChainlinkRandomnessProvider: _______________
RoundManager:                _______________
RewardVault:                 _______________
TickerNFT:                   _______________
TickerRegistry:              _______________
```

---

## PHASE D — Queue `RoundManager.setRewardVault(...)`

Governance-gated, behind the 48h timelock (Phase K/L), not executed now.
The deploy script itself logs the exact target + calldata for this — see
its own console output from Phase B. Queue it through the Safe once you're
ready to start the 48h clock (Phase K covers scheduling all timelocked
actions together).

---

## PHASE E — Deploy `VRFWrapperOnArbitrum`

Needs: `VRF_COORDINATOR_ARBITRUM`, `CCIP_ROUTER_ARBITRUM`,
`ROBINHOOD_CHAIN_SELECTOR`, `VRF_KEY_HASH`, `VRF_SUBSCRIPTION_ID` (from
Phase G — do this phase after creating the subscription), and
`ARBITRUM_GOVERNANCE_ADDRESS`.

```bash
export VRF_KEY_HASH=0x8472ba59cf7134dfe321f4d61a430c4857e8b19cdd5230b09952a92671c24409
export VRF_SUBSCRIPTION_ID=<from Phase G>
export ARBITRUM_GOVERNANCE_ADDRESS=<your Arbitrum governance address>
```

Dry run:

```bash
forge script script/DeployArbitrumWrapper.s.sol \
  --rpc-url https://arb1.arbitrum.io/rpc \
  --sig "run()"
```

Broadcast:

```bash
forge script script/DeployArbitrumWrapper.s.sol \
  --rpc-url https://arb1.arbitrum.io/rpc \
  --account clog-deployer-arbitrum \
  --broadcast \
  --sig "run()"
```

Record the deployed `VRFWrapperOnArbitrum` address now.

---

## PHASE F — Arbitrum ConfirmedOwner ownership sequence

`VRFWrapperOnArbitrum` inherits `VRFConsumerBaseV2Plus`'s `ConfirmedOwner` —
a two-step transfer. Distinguish the three roles explicitly, since they are
not necessarily the same address:

- **deployer** — `clog-deployer-arbitrum`, whoever broadcast Phase E. Owns
  the contract immediately after deployment.
- **current wrapper owner** — the deployer, until this phase completes.
- **`ARBITRUM_GOVERNANCE_ADDRESS`** — who Phase E's constructor already
  called `transferOwnership(ARBITRUM_GOVERNANCE_ADDRESS)` on, as its final
  step (see the deploy script's own source) — this only *proposes* the
  transfer; it is not accepted yet.

`ARBITRUM_GOVERNANCE_ADDRESS` itself must call `acceptOwnership()` to
complete the transfer:

```bash
cast send <VRFWrapperOnArbitrum address> "acceptOwnership()" \
  --rpc-url https://arb1.arbitrum.io/rpc \
  --account <whichever keystore controls ARBITRUM_GOVERNANCE_ADDRESS>
```

If `ARBITRUM_GOVERNANCE_ADDRESS` is a Safe, this is a Safe transaction, not
a plain `cast send` from an EOA keystore — queue it through the Safe UI
instead, calling `acceptOwnership()` on the wrapper.

Verify:

```bash
cast call <VRFWrapperOnArbitrum address> "owner()(address)" --rpc-url https://arb1.arbitrum.io/rpc
# expect: ARBITRUM_GOVERNANCE_ADDRESS, not the deployer
```

---

## PHASE G — Chainlink VRF subscription (you create/fund this personally)

Confirmed directly from `VRFWrapperOnArbitrum.sol`'s actual source
(`nativePayment: false`) — the subscription is funded with **LINK on
Arbitrum One**, not native ETH:

1. Create a VRF v2.5 subscription via Chainlink's subscription manager UI
   on Arbitrum One.
2. Fund it with LINK.
3. Add the deployed `VRFWrapperOnArbitrum` address (Phase E/C) as a
   consumer — either via the subscription manager UI, or:

```bash
cast send 0x3C0Ca683b403E37668AE3DC4FB62F4B29B6f7a3e \
  "addConsumer(uint256,address)" <VRF_SUBSCRIPTION_ID> <VRFWrapperOnArbitrum address> \
  --rpc-url https://arb1.arbitrum.io/rpc \
  --account clog-deployer-arbitrum
```

(This must be sent by the subscription's owner — whichever account created
it in step 1.)

Verify existence/config read-only:

```bash
cast call 0x3C0Ca683b403E37668AE3DC4FB62F4B29B6f7a3e \
  "getSubscription(uint256)(uint96,uint96,uint64,address,address[])" <VRF_SUBSCRIPTION_ID> \
  --rpc-url https://arb1.arbitrum.io/rpc
```

Do this before Phase E if you want `VRF_SUBSCRIPTION_ID` ready at wrapper
deploy time — the order between E and G only matters in that
`addConsumer` (step 3 above) needs the wrapper's address, which doesn't
exist until after Phase E. Practical order: create + fund the subscription
first (steps 1-2), deploy the wrapper (Phase E), then add it as a consumer
(step 3).

---

## PHASE H — Wrapper configuration: `setProvider(...)`

Governance-gated on Arbitrum One, called by `ARBITRUM_GOVERNANCE_ADDRESS`
(not the deployer) once ownership transfer (Phase F) is complete:

```bash
cast send <VRFWrapperOnArbitrum address> "setProvider(address)" <ChainlinkRandomnessProvider address from Phase C> \
  --rpc-url https://arb1.arbitrum.io/rpc \
  --account <whichever keystore controls ARBITRUM_GOVERNANCE_ADDRESS>
```

If `ARBITRUM_GOVERNANCE_ADDRESS` is a Safe, queue this as a Safe
transaction instead. `script/WireCrossChain.s.sol` (Phase J) logs this
exact calldata for you if you'd rather copy it from there than hand-type
the address.

---

## PHASE I — CCIP funding (ETH, not LINK — separate from Phase G)

Two ETH balances, entirely separate from the VRF subscription's LINK
balance above:

- **`ChainlinkRandomnessProvider`** (Robinhood Chain) — pays the outbound
  CCIP fee on every randomness request.
- **`VRFWrapperOnArbitrum`** (Arbitrum One) — pays the return CCIP fee on
  every `relayRandomness()` call.

No specific amount is prescribed — live CCIP fee pricing isn't knowable in
advance from here. Use Phase A's representative `getFee()` quotes as your
starting reference point, then fund modestly and monitor rather than
over-provisioning for a canary launch:

```bash
cast send <ChainlinkRandomnessProvider address> --value <amount> \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account clog-deployer-robinhood

cast send <VRFWrapperOnArbitrum address> --value <amount> \
  --rpc-url https://arb1.arbitrum.io/rpc \
  --account clog-deployer-arbitrum
```

If either balance runs dry later, the system degrades to a delay, never a
halt or a lost result — round closing/opening and VRF fulfillment are
fully decoupled from CCIP funding (see the protocol's own autonomy
architecture) — the affected step just becomes retryable once refunded.

---

## PHASE J — Cross-chain wiring: `WireCrossChain.s.sol`

Deploys nothing — reads real bytecode at both addresses (chain-aware: it
detects which side it's on from which address actually has local code, per
the real fix already on `main` — it will refuse to run if both or neither
address has code, rather than guessing) and logs the exact calldata for
whichever governance action applies to the chain you point it at:

```bash
export CHAINLINK_RANDOMNESS_PROVIDER=<from Phase C>
export VRF_WRAPPER_ON_ARBITRUM=<from Phase E/C>

forge script script/WireCrossChain.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --sig "run()"
forge script script/WireCrossChain.s.sol --rpc-url https://arb1.arbitrum.io/rpc --sig "run()"
```

The Robinhood run logs `ChainlinkRandomnessProvider.setWrapper(...)`'s
calldata (queue via Phase K, timelocked). The Arbitrum run logs
`VRFWrapperOnArbitrum.setProvider(...)`'s calldata — if you haven't already
executed Phase H by hand, use this output for it instead (same call,
whichever is more convenient).

---

## PHASE K — Robinhood 48h timelock: schedule everything

Every `onlyGovernance` function on Robinhood Chain is behind the
`TimelockController`'s 48h delay by design — no bootstrap bypass, even for
day-one wiring. Schedule both required actions together through the Safe
(as timelock proposer):

1. `RoundManager.setRewardVault(rewardVault)` — calldata from Phase D.
2. `ChainlinkRandomnessProvider.setWrapper(wrapperOnArbitrum)` — calldata
   from Phase J's Robinhood run.

The protocol cannot resolve any draw until both have cleared the delay and
executed (Phase L). Trading/launching does not depend on either — see the
First Telos section below.

---

## PHASE L — After 48 hours: execute + verify

Execute both scheduled actions through the Safe once the delay has passed,
then read back state to prove the configuration is actually correct rather
than assuming the transactions succeeded silently:

```bash
cast call <RoundManager address> "rewardVault()(address)" --rpc-url https://rpc.mainnet.chain.robinhood.com
# expect: the real RewardVault address from Phase C

cast call <ChainlinkRandomnessProvider address> "wrapperOnArbitrum()(address)" --rpc-url https://rpc.mainnet.chain.robinhood.com
# expect: the real VRFWrapperOnArbitrum address from Phase E/C
```

---

## PHASE M — Frontend env handoff

Populate the five frontend contract addresses + deployment block in
`/opt/clogged/.env.production` (see `POST_DEPLOY_HANDOFF.md` for the exact
list and sequence). No ABI regeneration is needed merely because addresses
changed — ABIs are keyed by contract shape, not address. Then, on the VPS:
`npm run build` (required — these are `NEXT_PUBLIC_*` values, baked in at
build time) followed by `sudo systemctl restart clog` (see
`VPS_RUNBOOK.md`).

---

## PHASE N — First manual live test

This is the **First Telos** (see below) — reachable immediately after
Phase M, without waiting for Phases G/H/J/K/L to complete. Connect a real
wallet, launch a real ticker, confirm the TickerNFT mints, confirm the
image/profile persist, confirm the metadata endpoint resolves, buy, sell,
confirm real balances/reserve/progress update in the UI.

The **Second Telos** — 3 qualified memes → close round → Chainlink → VRF →
winner → claim — only becomes reachable once Phases G through L have all
completed. Keeper automation comes after that manual draw succeeds, not
before.

---

## Product mechanics — unchanged, not renegotiable at deployment time

Launch fee 0.002 ETH (100% protocol multisig / 0% WinnerPot), 1B supply
(900M curve / 100M CLOG reserve, 0% to the creator), 0.6% trade tax (0.24%
ticker owner / 0.06% protocol / 0.30% WinnerPot), 5% *current* curve
progress (not a permanent high-water mark) + 0.229 ETH real reserve held
continuously for 30 minutes to qualify, minimum 3 candidates to draw,
uniform 1-in-N odds, TWAB-weighted claims with a 5-day window. None of
this changes for a canary launch — "small real amounts" means launching a
small number of memes and trading small ETH amounts against the real,
unmodified contracts.
