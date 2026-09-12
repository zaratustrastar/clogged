// Minimal, hand-written ABI for the real, official Uniswap Universal Router - only the entry
// points this app actually calls. NOT the full router ABI (which also covers v2/v3 swaps, NFT
// marketplace commands, etc. - all unused here). Matches the real, deployed Robinhood Chain
// Universal Router's `execute(bytes,bytes[])` and `execute(bytes,bytes[],uint256)` signatures,
// which are standard across Universal Router versions - see docs/V4_TRADING.md for the
// operator's own confirmation of which router version is actually deployed on Robinhood Chain
// and the encoding caveat that goes with it.
export const universalRouterAbi = [
  {
    type: "function",
    name: "execute",
    inputs: [
      { name: "commands", type: "bytes", internalType: "bytes" },
      { name: "inputs", type: "bytes[]", internalType: "bytes[]" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  {
    type: "function",
    name: "execute",
    inputs: [
      { name: "commands", type: "bytes", internalType: "bytes" },
      { name: "inputs", type: "bytes[]", internalType: "bytes[]" },
      { name: "deadline", type: "uint256", internalType: "uint256" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
] as const;
