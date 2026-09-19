# Protocol v2 deployment implications — economics + TWAB fix

Not a deployment script. This is the analysis Part E of the v2 task asked for: which
contracts a v2 deploy must touch, in what order, and what breaks if the cutover is done
carelessly. No transaction has been sent from this work; nothing here has been executed.

## Why nearly every contract needs a fresh address, not just the four that changed

Five contracts have real source changes:

- `MemeToken.sol` — new `marketInitializedAt` field + `totalSupplyTwab()` (the P0 fix).
- `RewardVault.sol` — `CLAIM_WINDOW` 90→5 days; `_circulatingTwab` now calls
  `totalSupplyTwab` instead of the bare `TOTAL_SUPPLY` constant; `IMemeTokenTWAB` interface
  changed to match.
- `BondingCurveClog.sol` — tax bps constants (60/60/4000/1000/5000).
- `TickerRegistry.sol` — `MULTISIG_LAUNCH_BPS` (10000); `_routeLaunchPayment` skips the
  now-zero WinnerPot call.
- `TickerNFT.sol` — now inherits `ERC2981`; a new `multisig_` constructor argument sets a
  fixed 5% secondary-sale royalty (see its own section below).

None of these are upgradeable, so each needs a brand-new on-chain instance. That alone
would only force those five addresses to change. The actual blast radius is much larger,
for a reason worth stating plainly: **this codebase resolves every circular deployment
dependency with a one-time setter** (`setRoundManager`, `setRewardVault`, `setRegistry`,
`setWrapper`), and every one of those setters can only fire once, ever, by design. A
contract whose own source is untouched still can't be reused if the thing it must
one-time-wire itself to is new.

Concretely:

- `RewardVault`'s constructor takes `roundManager` immutably. A new `RewardVault` needs a
  `RoundManager` that has never yet called `setRewardVault` — the current, live
  `RoundManager` already burned that call on the old `RewardVault`. **`RoundManager` must
  be redeployed too**, even though nothing in `RoundManager.sol` changed.
- The new `RoundManager`'s constructor takes `engine` (`EligibilityRegistry`) and
  `randomnessProvider` (`ChainlinkRandomnessProvider`). Both of *those* contracts already
  burned their own one-time `setRoundManager` call on the old `RoundManager`. **Both must
  be redeployed too**, again with unchanged source.
- `TickerRegistry`'s constructor takes `tickerNFT`. The live `TickerNFT` already burned its
  one-time `setRegistry` call on the old `TickerRegistry` - forcing a redeploy even if its
  source were unchanged. Its source is no longer unchanged either, as of the ERC-2981
  royalty addition below - real source change AND a forced redeploy, for the same address.
- `TickerRegistry.sol` also directly embeds `new MemeToken(...)` and
  `new BondingCurveClog(...)` — Solidity bakes a contract's creation bytecode into whatever
  contract calls `new` on it. Since `MemeToken.sol` and `BondingCurveClog.sol` both changed,
  `TickerRegistry`'s own bytecode is different regardless of `MULTISIG_LAUNCH_BPS` — it was
  already forced to redeploy on that count alone.

Net result: **every one of the six manifest addresses (`tickerRegistry`, `tickerNFT`,
`eligibilityRegistry`, `roundManager`, `rewardVault`, `chainlinkRandomnessProvider`)
becomes obsolete**. The cross-chain `arbitrumVrfWrapper` is the one exception - it needs a
single `setProvider` call re-pointing it at the new provider (see step 11 below), not a
redeploy, since that setter carries no one-time guard. Only `TimelockController`
(governance) has no CLOG-specific constructor dependency on any of this - it's a generic OZ
contract holding just proposer/executor roles - so it is safe to **reuse** for v2 if
continuity of governance is desired, or replace if a deliberate governance reset is also
intended. That is an operator decision, not a technical requirement either way.

## Clean deployment order (nothing executed — this is the sequence a real run would follow)

Mirrors `contracts/script/DeployRobinhoodChain.s.sol`'s own existing structure; no new
circular dependency was introduced by this task's changes, so the shape of the order is
unchanged from v1 — only every instance is new.

1. `TimelockController` — new instance, or reuse the existing one (see above). If reused,
   nothing to deploy here.
2. `EligibilityRegistry(deployer)` — new instance (forced by #4's setter being burned on
   the old one).
3. `ChainlinkRandomnessProvider(ccipRouter, arbitrumChainSelector, governance, deployer)` —
   new instance (same reason).
4. `RoundManager(engine=2, randomnessProvider=3, governance)` — new instance (its own
   source unchanged, but forced by `RewardVault`'s immutable constructor dependency, #6).
5. `engine.setRoundManager(4)` and `randomnessProvider.setRoundManager(4)` — one-time
   setters, called once each, on the *new* #2/#3 instances only.
6. `RewardVault(roundManager=4)` — new instance (real source change).
7. `TickerNFT(name, symbol, deployer, baseURI, multisig)` — new instance (forced by #8's
   setter being burned on the old one; also now carries the ERC-2981 royalty receiver -
   see the royalty section below - as its own constructor argument, fixed for the life of
   the contract).
8. `TickerRegistry(engine=2, tickerNFT=7, multisig, winnerPot=6, governance, seed params)`
   — new instance (real source change, plus the embedded MemeToken/BondingCurveClog
   creation-code change).
9. `tickerNFT.setRegistry(8)` — one-time setter, on the new #7 instance only.
10. Governance actions through the (reused-or-new) Timelock's propose → wait → execute
    flow, exactly as `_logRequiredGovernanceActions` already logs for a v1 deploy:
    `roundManager.setRewardVault(6)` and `randomnessProvider.setWrapper(...)`. These are
    *not* part of the atomic `run()` broadcast — they need the timelock delay to pass
    before they take effect, the same as today.
11. Cross-chain: `VRFWrapperOnArbitrum` (on Arbitrum One) must recognize the *new*
    `ChainlinkRandomnessProvider` address (#3) as `providerOnRobinhoodChain`. Checked
    directly against `VRFWrapperOnArbitrum.sol`'s own source rather than assumed: `setProvider`
    carries no one-time guard at all (only `onlyOwner`, freely re-callable) — so **the existing
    Arbitrum wrapper does not need to be redeployed**. A single governance-gated
    `setProvider(newProviderAddress)` call re-points it at the new v2 provider, reusing the
    same wrapper, the same Chainlink VRF subscription, and the same LINK funding — a
    materially smaller operational lift than a fresh wrapper + fresh VRF subscription would
    be. `WireCrossChainVerification.t.sol`'s own tests exercise this exact detection/wiring
    path and are the right place to confirm end to end once real addresses exist.

Step order matters: 2/3 before 4 (constructor args), 4 before 5 and before 6 (constructor
arg), 5 before anything that depends on RoundManager knowing engine/provider are live, 7
before 8 (constructor arg), 8 before 9. Steps 2+3, and 7, have no dependency on each other
and could be parallelized if convenient, but there is no reason to.

## TickerNFT secondary-sale royalty (ERC-2981)

Every new v2 `TickerNFT` advertises a 5% secondary-sale royalty (`ROYALTY_BPS = 500` of
ERC-2981's default 10,000 denominator), paid entirely to the protocol multisig, set once in
the constructor via `_setDefaultRoyalty` and never changeable afterward - no external
setter exists anywhere in the contract, by design. This is set once per deployment, the
same way `deployer`/`baseURI` already are - there is nothing further to configure or wire
post-deployment; `_setDefaultRoyalty` runs inside the constructor itself, in the same
transaction as deployment.

This is a completely separate revenue stream from the 0.002 ETH ticker launch fee
(`TickerRegistry`), the 0.6% meme-token trading tax, and the ticker owner's 40% share of
that tax (`BondingCurveClog`) - none of those change because of this, and this royalty
neither reduces nor replaces any of them.

**Signaling only, not enforcement** - stated here as plainly as in the contract's own doc
comment, since it is the one property of this feature most likely to be silently
misunderstood by an operator or a future contributor: ERC-2981's `royaltyInfo` tells a
marketplace what royalty *should* be paid and to whom. It cannot, and structurally does
not, force any marketplace, OTC transfer, or a plain `transferFrom` call to actually pay
it. A marketplace that does not honor ERC-2981, or a direct wallet-to-wallet transfer
outside any marketplace, moves the NFT with zero royalty enforced by this contract or the
chain itself. No transfer restriction, marketplace allowlist, or custom in-protocol
marketplace was added to work around that limitation - see `TickerNFT.sol`'s own doc
comment for the same reasoning stated in the contract itself.

No deployment-script action beyond passing `multisig` as the new constructor argument (see
step 7 above) is required for this feature - there is no separate registration step with
any marketplace, and none would be effective even if attempted, per the limitation above.

## Frontend manifest / address files that must change

- `deployments/robinhood-mainnet.json` — every one of the 5 frontend-facing addresses
  (`tickerRegistry`, `tickerNFT`, `eligibilityRegistry`, `roundManager`, `rewardVault`) plus
  the `$notReadByFrontend` operational ones - `chainlinkRandomnessProvider` gets a new
  address; `arbitrumVrfWrapper` itself is reused (see the cross-chain note above) but its
  own recorded `providerOnRobinhoodChain` value in any operational docs/scripts should be
  updated to match. **`deploymentBlock` must also change** to the new `TickerRegistry`'s own
  deployment block, confirmed the same way the current value was — from that contract's
  real deployment transaction receipt, never guessed or copied from the old value. Getting
  this wrong doesn't just misattribute history: `useRoundHistory`'s incremental scan (see
  the earlier RPC-resilience work) starts from `deploymentBlock` on every fresh scan-state,
  so a stale, too-early value forces every new deploy to needlessly re-scan the entire old
  v1 history looking for `RoundSettled` events that will never be emitted by the new
  `RoundManager`, and a too-late value would silently miss whatever real v2 rounds happened
  before the wrong `deploymentBlock`.
- `docs/DEPLOYMENTS.md` / `POST_DEPLOY_HANDOFF.md` — likely reference the current addresses
  in prose or examples; worth a read-through and update once real v2 addresses exist,
  though this task does not touch them since there is nothing real to write in yet.
- No other frontend source file should need a manual address edit — `lib/web3/env.ts` and
  `lib/web3/addresses.ts` read from this manifest, per the existing "single source of
  truth" design; that architecture does not change.

## Keeper configuration that must change

The keeper holds its own copy of the same address set (`roundManager`, `eligibilityRegistry`,
`rewardVault`, `deploymentBlock`, plus whichever of `tickerRegistry`/`tickerNFT` it reads)
via its own config/env, independent of the frontend's manifest file. All of these need the
same new v2 addresses and the same new `deploymentBlock`. The keeper does not persist scan
state to disk between runs (confirmed by this session's earlier RPC-resilience work — its
`lastScannedBlock` cache is a module-level in-memory value, reset on every process restart),
so there is no stale on-disk cursor to worry about separately; a keeper restarted against
the new config will naturally begin scanning from the new `deploymentBlock` forward.

## Historical canary Round 1 claims: old RewardVault only, and NOT on the new 5-day window

This is the sharpest edge case in the whole cutover, worth stating without hedging: **the
old `RewardVault` instance keeps existing on-chain, immutable, with its own `allocations[1]`
state intact.** Nothing about deploying a new `RewardVault` migrates, copies, or invalidates
that state. A wallet with a real, unclaimed Round 1 reward can only ever claim it by calling
`claim`/`previewClaim` against the **old** `RewardVault` address — the new `RewardVault`
starts with empty `allocations` and has no way to know Round 1 ever happened.

Two consequences that must not be silently lost in the cutover:

1. The old Round 1 allocation's claim window is governed by the *old* `RewardVault`'s own
   compiled-in `CLAIM_WINDOW` (90 days, from `allocatedAt`), not the new 5-day value — that
   constant lives in the old contract's own immutable bytecode and does not change no
   matter what the new contract says.
2. If the frontend's manifest simply flips over to the new `rewardVault` address (as the
   "single source of truth" design above implies it naturally would), the dashboard loses
   all visibility into the old Round 1 claim the moment the manifest changes — not because
   the reward stopped existing, but because nothing in the UI would know to look at the old
   address anymore. Before cutting the frontend over, either (a) confirm every legitimate
   Round 1 holder has already claimed from the old `RewardVault`, or (b) keep a
   deliberate, explicit "legacy claims" path in the frontend/manifest pointing at the old
   `rewardVault` address for whatever remains of its own 90-day window, rather than letting
   it become invisible by omission. This is a product/operator decision, not something this
   task resolves unilaterally — flagged here for that decision, not silently assumed either
   way.

## Never silently mix v1 and v2

Every new v2 contract's constructor must be given another *new* v2 contract's address, never
an old v1 one — e.g. the new `TickerRegistry` must be constructed with the new `RewardVault`
address as `winnerPot`, never the old one, or every future ticker launched against it would
silently route its 0.6% trading tax into a `RewardVault` instance nobody is claiming from
through the current frontend. This is naturally enforced by following the deployment order
above (each step's constructor args come from a step already completed *in this same v2
run*), but is worth stating as an explicit pre-flight check for whoever runs the real script
- particularly around environment variables, since a copy-pasted `.env` from the v1 deploy
would reintroduce exactly this failure mode silently.

## What this document does not do

It does not deploy anything, run the deploy script, send any transaction, or create any new
address. It does not modify `contracts/script/DeployRobinhoodChain.s.sol`'s own structure
(only the two literal values already fixed elsewhere in this task: the launch-fee-split
constant reference and the `CLAIM_WINDOW` verification's expected value). It does not
resolve the Round 1 legacy-claims product question above - that decision belongs to
whoever approves the real cutover.
