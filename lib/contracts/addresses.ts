// Contract addresses, kept separate from ABIs and from component code so
// deploying to a new environment (testnet vs mainnet) never means hunting
// through the app.
//
// TODO (live wiring): fill these in from the deployment record (see
// DeployRobinhoodChain.s.sol / DeployArbitrumWrapper.s.sol output) once the
// protocol is deployed. Consider loading these from an env-var-driven config
// per NEXT_PUBLIC_CHAIN_ID instead of a static object, if the app needs to
// support both a testnet and mainnet deployment simultaneously.

export const CONTRACT_ADDRESSES = {
  robinhoodChain: {
    tickerRegistry: "0x0000000000000000000000000000000000000000",
    tickerNFT: "0x0000000000000000000000000000000000000000",
    eligibilityRegistry: "0x0000000000000000000000000000000000000000",
    roundManager: "0x0000000000000000000000000000000000000000",
    rewardVault: "0x0000000000000000000000000000000000000000",
    chainlinkRandomnessProvider: "0x0000000000000000000000000000000000000000",
    timelock: "0x0000000000000000000000000000000000000000",
  },
} as const;

// TODO (live wiring): replace with Robinhood Chain's real chain ID.
export const ROBINHOOD_CHAIN_ID = 0;
