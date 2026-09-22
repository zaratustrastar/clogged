// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @title HookMinerV2
/// @notice Finds a CREATE2 salt such that the resulting ClogV4HookV2 address has EXACTLY the
///         required v4-core hook permission bits set: BEFORE_INITIALIZE (1<<13) |
///         BEFORE_ADD_LIQUIDITY (1<<11) | BEFORE_REMOVE_LIQUIDITY (1<<9) | BEFORE_SWAP (1<<7) |
///         AFTER_SWAP (1<<6) | BEFORE_SWAP_RETURNS_DELTA (1<<3)
///         = 8192 + 2048 + 512 + 128 + 64 + 8 = 10952 = 0x2AC8, confirmed directly against
///         Hooks.sol's own flag constants (see BroadcastCreate2Check.t.sol-style verification
///         methodology used throughout this profile) rather than assumed. V1's hook used
///         0x2088 (no liquidity-gating flags, no AFTER_SWAP) - V2 needs afterSwap for the
///         slot0 postcondition check and beforeAddLiquidity/beforeRemoveLiquidity to prevent
///         any outsider from adding ordinary LP to a pool this hook governs, so a genuinely
///         new hook address is required; the old one could never satisfy this mask no matter
///         what code lives at it.
library HookMinerV2 {
    uint160 internal constant REQUIRED_FLAGS = uint160(0x2AC8);
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    function find(Vm vm, address deployer, bytes32 initCodeHash, uint256 maxIterations)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        for (uint256 i = 0; i < maxIterations; i++) {
            salt = bytes32(i);
            address candidate = vm.computeCreate2Address(salt, initCodeHash, deployer);
            if (uint160(candidate) & ALL_HOOK_MASK == REQUIRED_FLAGS) {
                return (candidate, salt);
            }
        }
        revert("HookMinerV2: no salt found within maxIterations");
    }

    function hashInitCode(bytes memory creationCodeWithArgs) internal pure returns (bytes32) {
        return keccak256(creationCodeWithArgs);
    }
}
