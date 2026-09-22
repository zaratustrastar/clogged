# Genuine-architecture canary deployment

Source architecture is **frozen**. This directory adds deployment infrastructure only —
`ClogMarket.sol`, `ClogGenuineLiquidityHook.sol`, `ClogFourPositionMath.sol` and
`ClogGenuineRegistry.sol` are untouched.

Parent commit: `73c01bffee1bbe2491b21ebf4c792cab966f0500`

## What the script deploys and wires

`EligibilityRegistry` → `TickerNFT` → `ClogFourPositionMath(HI)` → `ClogGenuineRegistry` →
`ClogGenuineLiquidityHook` (CREATE2, mined for mask `0x2ACC`) → `RewardVault`, then
`registry.setV4Infrastructure(...)` and `nft.setRegistry(...)`.

It does **not** launch a ticker and does **not** trade.

Frozen parameters: virtual ETH seed `9 ether`, buffer `20_000`, tickSpacing `1`,
launch fee exactly `0.002 ETH` → Safe `0x29DEf4F5429CAC1e364263C449A7aE791657d48F`.

## Simulate (no broadcast, no keystore)

```bash
forge script script-v4/DeployGenuineCanary.s.sol:DeployGenuineCanary \
  --profile v4 --use 0.8.26 \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --sender <DEPLOYER_ADDRESS> \
  -vvv
```

## Broadcast (only when approved)

```bash
forge script script-v4/DeployGenuineCanary.s.sol:DeployGenuineCanary \
  --profile v4 --use 0.8.26 \
  --rpc-url https://rpc.mainnet.chain.robinhood.com \
  --account clog-deployer-robinhood \
  --broadcast -vvv
```

No private key appears in this repository. Signing is done entirely by the named keystore.

Optional env overrides: `CLOG_MULTISIG`, `CLOG_ROUND_MANAGER`, `CLOG_BASE_URI`.

## Simulated run (chain 4663)

```
hook flag mask 0x2ACC     OK
runtime bytecode present  OK
registry/hook/vault/nft   OK
Safe + economics          OK
estimated gas             14,592,782
estimated cost            0.001612677538976782 ETH
```

Addresses from the dry run are **nonce-dependent** and will differ on broadcast: the hook's
CREATE2 salt is mined against the Registry address, which depends on the deployer's nonce. The
script re-mines at run time and asserts `CREATE2 address mismatch` if prediction and deployment
ever disagree, so this is safe — but do not treat dry-run addresses as final.

## Access control on the infrastructure wiring

`setV4Infrastructure` was originally **unguarded** — anyone could re-point `poolManager`, `hook`
and `rewardVault`, and since `hook.setRewardVault` is `onlyRegistry` that allowed redirecting the
WinnerPot to an attacker-controlled vault.

It is now `configurator`-only and **one-shot**:

```solidity
address public immutable configurator;   // set to msg.sender in the constructor

if (msg.sender != configurator) revert NotConfigurator();
if (address(poolManager) != address(0) || address(hook) != address(0) || rewardVault != address(0))
    revert AlreadyConfigured();
if (pm == address(0) || hook_ == address(0) || vault == address(0)) revert ZeroAddress();
```

No transfer, no ownership, no proxy, no reconfiguration — not even by the configurator.
`hook.setRewardVault` remains `onlyRegistry` and was not touched.

Covered by `test-v4/genuine/RegistryAccessControl.t.sol` (9 tests), including the original
exploit path. The deploy script now also asserts `configurator == deployer`, that the
infrastructure is configured, and that a second `setV4Infrastructure` call reverts.
