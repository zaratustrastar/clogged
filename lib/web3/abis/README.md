# Generated ABIs — provenance

Every file in this directory is generated mechanically via:

```
forge inspect src/<Contract>.sol:<Contract> abi --json
```

run against `contracts/src/` in this same repository, never hand-edited.

**Source commit:** `13814ec` (`Fix WireCrossChain.s.sol: provider and wrapper never share a chain`)

To regenerate after any contract change, run the same `forge inspect`
command for each contract from `contracts/`, convert the JSON output to a
`export const <name>Abi = [...] as const;` file, and update the commit hash
above.

## Which functions the frontend actually consumes

The ABIs are complete (every function/event on each contract), but the
frontend deliberately does not expose every function in the UI — only what's
part of current product UX:

- **RoundManager**: `closeRoundAndOpenNext`, `requestRandomnessForRound`,
  `getRound`, `currentRoundId`, `currentRoundOpenTime`, `ROUND_DURATION`,
  `MIN_DRAW_CANDIDATES` are read/called by the frontend. `setRandomnessProvider`/
  `setRewardVault` (governance-only) are not exposed anywhere in the UI —
  those are Safe/timelock operations, not end-user actions.
- **VRFWrapperOnArbitrum**/**ChainlinkRandomnessProvider**: not called by the
  frontend at all (Arbitrum-side infrastructure, invisible to end users per
  the product's own design — "users interact only with Robinhood Chain").
  Not included in this ABI set for that reason.
- **EligibilityRegistry**: `onTrade` is never called directly by the
  frontend (it's invoked atomically by `BondingCurveClog` itself now, not a
  separate frontend action) — only `qualify` (the permissionless manual
  confirm action) and the read functions are used.
