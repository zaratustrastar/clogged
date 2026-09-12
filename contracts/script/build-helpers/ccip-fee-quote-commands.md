# Exact read-only CCIP fee quote commands (canary)

These are genuine `cast call` invocations against the REAL, live CCIP routers on both chains -
read-only (`eth_call`), no transaction, no broadcast, no state change. They reproduce the EXACT
message shape `ChainlinkRandomnessProvider.requestRandomness()` / `VRFWrapperOnArbitrum`'s own
return leg construct internally (verified directly against `src/ChainlinkRandomnessProvider.sol`
line ~108-121 and `src/VRFWrapperOnArbitrum.sol` line ~175-186), so the quoted fee matches what a
real request/relay would actually be charged - not an approximation.

`receiver` in both commands is `abi.encode(address(1))` - a placeholder, since the real wrapper/
provider addresses don't exist until after deployment. CCIP fees are priced by message size and
destination gas limit, not the specific receiver address, so this does not distort the quote.

## Robinhood -> Arbitrum (the outbound leg `requestRandomness` pays)

Router: `0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9` (Robinhood CCIP Router)
Destination selector: `4949039107694359620` (Arbitrum One)
`data`: `abi.encode(requestId)` - a single `uint256`, e.g. `abi.encode(uint256(1))`

```bash
cast call 0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9 \
  "getFee(uint64,(bytes,bytes,(address,uint256)[],address,bytes))" \
  4949039107694359620 \
  "(0x0000000000000000000000000000000000000000000000000000000000000001,0x0000000000000000000000000000000000000000000000000000000000000001,[],0x0000000000000000000000000000000000000000,0x181dcf1000000000000000000000000000000000000000000000000000000000000493e00000000000000000000000000000000000000000000000000000000000000001)" \
  --rpc-url https://rpc.mainnet.chain.robinhood.com
```

Result is the fee in wei of native ETH on Robinhood Chain.

## Arbitrum -> Robinhood (the return leg `relayRandomness` pays)

Router: `0x141fa059441E0ca23ce184B6A78bafD2A517DdE8` (Arbitrum CCIP Router)
Destination selector: `6180753054346818345` (Robinhood Chain)
`data`: `abi.encode(originalRequestId, randomWord)` - a pair of `uint256`, e.g.
`abi.encode(uint256(1), uint256(1))`

```bash
cast call 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8 \
  "getFee(uint64,(bytes,bytes,(address,uint256)[],address,bytes))" \
  6180753054346818345 \
  "(0x0000000000000000000000000000000000000000000000000000000000000001,0x00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001,[],0x0000000000000000000000000000000000000000,0x181dcf1000000000000000000000000000000000000000000000000000000000000493e00000000000000000000000000000000000000000000000000000000000000001)" \
  --rpc-url https://arb1.arbitrum.io/rpc
```

Result is the fee in wei of native ETH on Arbitrum One - this is what the Arbitrum wrapper must be
funded with (in ETH, since it needs to pay this fee in its own native gas token, bridged/held on
Arbitrum), separately from the Robinhood-side provider's funding for the outbound leg above.

## Notes

- The `extraArgs` hex (`0x181dcf10...000001`) encodes `GenericExtraArgsV2{gasLimit: 300_000,
  allowOutOfOrderExecution: true}` via CCIP's own `Client._argsToBytes` encoding (tag
  `0x181dcf10`, confirmed directly against the vendored `Client.sol`) - the exact same
  `DEST_CALLBACK_GAS_LIMIT` both real contracts use.
- Both commands return a single `uint256` (wei). Decode with `cast --to-dec` if the raw hex return
  needs converting, though `cast call` on a function returning `uint256` already prints it decoded.
- These fees fluctuate with real-time gas prices on both chains and LINK/ETH pricing feeds CCIP
  uses internally - re-run immediately before funding, not from a stale quote.
