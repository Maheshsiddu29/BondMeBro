// GENERATED FILE — do not edit by hand.
// Source: out/BondMeBro.sol/BondMeBro.json (`forge build` at the repository root).
// Regenerate with: node frontend/scripts/sync-abi.mjs
//
// This is the exact compiled surface of the hook on the current contract baseline,
// narrowed to the entries the dashboard uses. Getter, setter and event field orders
// differ from one another for PoolConfig; they are preserved verbatim here and must
// never be collapsed into one shared positional tuple.
import type { Abi } from "viem";

export const bondMeBroAbi = [
  {
    "type": "function",
    "name": "BPS",
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
    "name": "MAX_BOND_BPS",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "OBSERVATION_BLOCKS",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint32",
        "internalType": "uint32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "MAX_SETTLE_BATCH",
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
    "name": "owner",
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
    "name": "poolManager",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IPoolManager"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "poolConfig",
    "inputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "PoolId"
      }
    ],
    "outputs": [
      {
        "name": "minBondedAmount0",
        "type": "uint128",
        "internalType": "uint128"
      },
      {
        "name": "minBondedAmount1",
        "type": "uint96",
        "internalType": "uint96"
      },
      {
        "name": "bondingEnabled",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "minVariableLeg0",
        "type": "uint128",
        "internalType": "uint128"
      },
      {
        "name": "minVariableLeg1",
        "type": "uint128",
        "internalType": "uint128"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "setPoolConfig",
    "inputs": [
      {
        "name": "key",
        "type": "tuple",
        "internalType": "struct PoolKey",
        "components": [
          {
            "name": "currency0",
            "type": "address",
            "internalType": "Currency"
          },
          {
            "name": "currency1",
            "type": "address",
            "internalType": "Currency"
          },
          {
            "name": "fee",
            "type": "uint24",
            "internalType": "uint24"
          },
          {
            "name": "tickSpacing",
            "type": "int24",
            "internalType": "int24"
          },
          {
            "name": "hooks",
            "type": "address",
            "internalType": "contract IHooks"
          }
        ]
      },
      {
        "name": "minBondedAmount0",
        "type": "uint128",
        "internalType": "uint128"
      },
      {
        "name": "minBondedAmount1",
        "type": "uint96",
        "internalType": "uint96"
      },
      {
        "name": "minVariableLeg0",
        "type": "uint128",
        "internalType": "uint128"
      },
      {
        "name": "minVariableLeg1",
        "type": "uint128",
        "internalType": "uint128"
      },
      {
        "name": "bondingEnabled",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getBond",
    "inputs": [
      {
        "name": "bondId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "bond",
        "type": "tuple",
        "internalType": "struct BondMeBro.Bond",
        "components": [
          {
            "name": "refundRecipient",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "openBlock",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "maturityBlock",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "poolIndex",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "variableLegAmount",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "tickBefore",
            "type": "int24",
            "internalType": "int24"
          },
          {
            "name": "tickAfter",
            "type": "int24",
            "internalType": "int24"
          },
          {
            "name": "collateralBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "collateralIsCurrency0",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "state",
            "type": "uint8",
            "internalType": "enum BondMeBro.BondState"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "bondExists",
    "inputs": [
      {
        "name": "bondId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "collateralAmountOf",
    "inputs": [
      {
        "name": "bondId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "collateral",
        "type": "uint128",
        "internalType": "uint128"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "insurancePot",
    "inputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "PoolId"
      },
      {
        "name": "",
        "type": "address",
        "internalType": "Currency"
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
    "name": "accumulator",
    "inputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "PoolId"
      }
    ],
    "outputs": [
      {
        "name": "lastTick",
        "type": "int24",
        "internalType": "int24"
      },
      {
        "name": "lastUpdate",
        "type": "uint32",
        "internalType": "uint32"
      },
      {
        "name": "blockStartTick",
        "type": "int24",
        "internalType": "int24"
      },
      {
        "name": "tickCumulative",
        "type": "int56",
        "internalType": "int56"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "blockStartTickOf",
    "inputs": [
      {
        "name": "id",
        "type": "bytes32",
        "internalType": "PoolId"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "int24",
        "internalType": "int24"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "effectiveCollateralBpsFor",
    "inputs": [
      {
        "name": "tickBefore",
        "type": "int24",
        "internalType": "int24"
      },
      {
        "name": "tickAfter",
        "type": "int24",
        "internalType": "int24"
      },
      {
        "name": "blockStartTick",
        "type": "int24",
        "internalType": "int24"
      }
    ],
    "outputs": [
      {
        "name": "collateralBps",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "settleBond",
    "inputs": [
      {
        "name": "bondId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "settleMany",
    "inputs": [
      {
        "name": "bondIds",
        "type": "bytes32[]",
        "internalType": "bytes32[]"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "BondOpened",
    "inputs": [
      {
        "name": "bondId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "id",
        "type": "bytes32",
        "indexed": true,
        "internalType": "PoolId"
      },
      {
        "name": "refundRecipient",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "variableLegAmount",
        "type": "uint128",
        "indexed": false,
        "internalType": "uint128"
      },
      {
        "name": "maturityBlock",
        "type": "uint32",
        "indexed": false,
        "internalType": "uint32"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "BondTaken",
    "inputs": [
      {
        "name": "id",
        "type": "bytes32",
        "indexed": true,
        "internalType": "PoolId"
      },
      {
        "name": "refundRecipient",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "currency",
        "type": "address",
        "indexed": true,
        "internalType": "Currency"
      },
      {
        "name": "bond",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "variableLegAmount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "BondSettled",
    "inputs": [
      {
        "name": "bondId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "id",
        "type": "bytes32",
        "indexed": true,
        "internalType": "PoolId"
      },
      {
        "name": "refundRecipient",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "currency",
        "type": "address",
        "indexed": false,
        "internalType": "Currency"
      },
      {
        "name": "collateral",
        "type": "uint128",
        "indexed": false,
        "internalType": "uint128"
      },
      {
        "name": "refund",
        "type": "uint128",
        "indexed": false,
        "internalType": "uint128"
      },
      {
        "name": "slash",
        "type": "uint128",
        "indexed": false,
        "internalType": "uint128"
      },
      {
        "name": "slashBps",
        "type": "uint16",
        "indexed": false,
        "internalType": "uint16"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PoolConfigured",
    "inputs": [
      {
        "name": "id",
        "type": "bytes32",
        "indexed": true,
        "internalType": "PoolId"
      },
      {
        "name": "minBondedAmount0",
        "type": "uint128",
        "indexed": false,
        "internalType": "uint128"
      },
      {
        "name": "minBondedAmount1",
        "type": "uint96",
        "indexed": false,
        "internalType": "uint96"
      },
      {
        "name": "minVariableLeg0",
        "type": "uint128",
        "indexed": false,
        "internalType": "uint128"
      },
      {
        "name": "minVariableLeg1",
        "type": "uint128",
        "indexed": false,
        "internalType": "uint128"
      },
      {
        "name": "bondingEnabled",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "BondExceedsTraderMax",
    "inputs": [
      {
        "name": "bond",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "maxBondAmount",
        "type": "uint128",
        "internalType": "uint128"
      }
    ]
  },
  {
    "type": "error",
    "name": "BondNotFound",
    "inputs": [
      {
        "name": "bondId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "BondNotMature",
    "inputs": [
      {
        "name": "bondId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "maturityBlock",
        "type": "uint32",
        "internalType": "uint32"
      },
      {
        "name": "currentBlock",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "BondNotSettleable",
    "inputs": [
      {
        "name": "bondId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "state",
        "type": "uint8",
        "internalType": "enum BondMeBro.BondState"
      }
    ]
  },
  {
    "type": "error",
    "name": "BondViolatesNoOpVLBound",
    "inputs": [
      {
        "name": "bond",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "variableLegAmount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "IncompleteBondingConfig",
    "inputs": [
      {
        "name": "minBondedAmount0",
        "type": "uint128",
        "internalType": "uint128"
      },
      {
        "name": "minBondedAmount1",
        "type": "uint96",
        "internalType": "uint96"
      }
    ]
  },
  {
    "type": "error",
    "name": "InvalidHookDataLength",
    "inputs": [
      {
        "name": "expected",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "actual",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "MaturityCheckpointMissing",
    "inputs": [
      {
        "name": "bondId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "maturityBlock",
        "type": "uint32",
        "internalType": "uint32"
      },
      {
        "name": "lastUpdate",
        "type": "uint32",
        "internalType": "uint32"
      }
    ]
  },
  {
    "type": "error",
    "name": "MissingHookData",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotOwner",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PoolNotRegistered",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SettleBatchTooLarge",
    "inputs": [
      {
        "name": "length",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "cap",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "UnsupportedHookDataVersion",
    "inputs": [
      {
        "name": "version",
        "type": "uint8",
        "internalType": "uint8"
      }
    ]
  },
  {
    "type": "error",
    "name": "VariableLegMinimumTooSmall",
    "inputs": [
      {
        "name": "provided",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "required",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ZeroMaxBondAmount",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ZeroRefundRecipient",
    "inputs": []
  }
] as const satisfies Abi;

export type BondMeBroAbi = typeof bondMeBroAbi;
