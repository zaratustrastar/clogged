// Minimal, hand-written ABI for the canonical Permit2 contract
// (0x000000000022D473030F116dDEE9F6B43aC78BA3, identical address on every chain, including
// Robinhood Chain) - only the AllowanceTransfer functions this app's v4 sell path actually calls.
export const permit2Abi = [
  {
    type: "function",
    name: "approve",
    inputs: [
      { name: "token", type: "address", internalType: "address" },
      { name: "spender", type: "address", internalType: "address" },
      { name: "amount", type: "uint160", internalType: "uint160" },
      { name: "expiration", type: "uint48", internalType: "uint48" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "allowance",
    inputs: [
      { name: "owner", type: "address", internalType: "address" },
      { name: "token", type: "address", internalType: "address" },
      { name: "spender", type: "address", internalType: "address" },
    ],
    outputs: [
      { name: "amount", type: "uint160", internalType: "uint160" },
      { name: "expiration", type: "uint48", internalType: "uint48" },
      { name: "nonce", type: "uint48", internalType: "uint48" },
    ],
    stateMutability: "view",
  },
] as const;
