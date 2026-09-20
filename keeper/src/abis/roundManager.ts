// Generated mechanically from the compiled contract via
// `forge inspect src/RoundManager.sol:RoundManager abi --json`, run against
// contracts/src/ at the canary-validation branch tip (commit ab0a42f). Do not
// hand-edit - regenerate from the frozen contract source if the ABI needs to change.
export const roundManagerAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "engine_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "randomnessProvider_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "governance_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "roundDuration_",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "MIN_DRAW_CANDIDATES",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "closeRoundAndOpenNext",
    "inputs": [],
    "outputs": [
      {
        "name": "closedRoundId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "currentRoundId",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "currentRoundOpenTime",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "engine",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract EligibilityRegistry"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "exposedUnbiasedIndex",
    "inputs": [
      {
        "name": "randomWord",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "roundId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "n",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "getRound",
    "inputs": [
      {
        "name": "roundId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct RoundManager.RoundInfo",
        "components": [
          {
            "name": "openTime",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "closeTime",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "candidateRoundId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "candidateCount",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "closed",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "drawSkipped",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "randomnessRequested",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "randomnessRequestId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "settled",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "winnerTokenId",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "governance",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "onRandomnessReceived",
    "inputs": [
      {
        "name": "requestId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "randomWord",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "randomnessProvider",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IRandomnessProvider"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "requestIdToRoundId",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "requestRandomnessForRound",
    "inputs": [
      {
        "name": "roundId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "rewardVault",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IRewardVault"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "ROUND_DURATION",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "rounds",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "openTime",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "closeTime",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "candidateRoundId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "candidateCount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "closed",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "drawSkipped",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "randomnessRequested",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "randomnessRequestId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "settled",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "winnerTokenId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "setRandomnessProvider",
    "inputs": [
      {
        "name": "newProvider",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setRewardVault",
    "inputs": [
      {
        "name": "newVault",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "RandomnessProviderUpdated",
    "inputs": [
      {
        "name": "newProvider",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RandomnessRequestFailed",
    "inputs": [
      {
        "name": "roundId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RandomnessRequested",
    "inputs": [
      {
        "name": "roundId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "requestId",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RewardVaultUpdated",
    "inputs": [
      {
        "name": "newVault",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RoundClosed",
    "inputs": [
      {
        "name": "roundId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "closeTime",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "candidateCount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "drawSkipped",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RoundSettled",
    "inputs": [
      {
        "name": "roundId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "winnerTokenId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "randomWord",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  }
] as const;
