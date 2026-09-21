// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @title HookMiner
/// @notice Finds a CREATE2 salt such that the resulting ClogV4Hook address has EXACTLY the
///         required v4-core hook permission bits set in its low 14 bits, and none of the
///         others - confirmed directly against Hooks.sol source before writing this:
///         ALL_HOOK_MASK = (1<<14)-1, and PoolManager itself decides whether to invoke each
///         hook callback purely by testing the corresponding bit of the hook's OWN address
///         (Hooks.hasPermission), not from any separate on-chain declaration. This is
///         test/script-only tooling (it uses the Vm cheatcode interface directly, never
///         imported by production source under src-v4/), used identically by tests that want a
///         REAL, CREATE2-deployed hook address (as opposed to the vm.etch shortcut used
///         elsewhere in this profile to iterate quickly once a valid address is already known)
///         and by whatever deploy script eventually performs the real deployment.
library HookMiner {
    // BEFORE_INITIALIZE_FLAG (1<<13) | BEFORE_SWAP_FLAG (1<<7) | BEFORE_SWAP_RETURNS_DELTA_FLAG
    // (1<<3) = 8192 + 128 + 8 = 8328 = 0x2088 - identical to the flag pattern used via vm.etch
    // throughout the rest of this profile (ClogV4HookBuySell.t.sol and others), confirmed
    // against Hooks.sol's own constants directly, not assumed.
    uint160 internal constant REQUIRED_FLAGS = uint160(0x2088);
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    /// @notice Searches salts starting at 0 for one whose CREATE2 address (given `deployer` and
    ///         `initCodeHash`) has exactly REQUIRED_FLAGS set among the low 14 bits and nothing
    ///         else in that range. Reverts if none is found within `maxIterations` - callers
    ///         should treat that as a real, unexpected failure (the birthday-paradox-style
    ///         density of matching addresses across a 14-bit mask is high enough that
    ///         `maxIterations` in the tens of thousands is already extremely conservative).
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
        revert("HookMiner: no salt found within maxIterations");
    }

    /// @dev Convenience: the exact init code hash for a ClogV4Hook deployment with given
    ///      constructor args, computed the same way CREATE2 itself does
    ///      (keccak256(creationCode ++ abi.encode(args))) - callers pass
    ///      `abi.encodePacked(creationCode, abi.encode(poolManager, launchInitializer))`.
    function hashInitCode(bytes memory creationCodeWithArgs) internal pure returns (bytes32) {
        return keccak256(creationCodeWithArgs);
    }
}
