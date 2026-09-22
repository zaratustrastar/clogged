// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Independently verifies the candidate hook permission mask by importing Hooks.sol's
///         own constants directly - not by hand-copying flag bit values into this repo. If
///         Hooks.sol's own constants ever change, this test recomputes from them, not from a
///         previously hand-calculated number.
contract HookMaskVerification is Test {
    function test_candidateMask_matchesHooksSol_ownConstants() public pure {
        uint160 computedMask = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        assertEq(computedMask, 0x2AC8, "the candidate mask must equal exactly what Hooks.sol's own constants compute to");

        // Also confirm what is explicitly NOT included, addressing V1's exact prior mask
        // (0x2088) plus the two new liquidity gates and AFTER_SWAP - nothing else.
        assertEq(uint160(Hooks.AFTER_INITIALIZE_FLAG), 1 << 12);
        assertEq(uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG), 1 << 10);
        assertEq(uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG), 1 << 8);
        assertEq(uint160(Hooks.BEFORE_DONATE_FLAG), 1 << 5);
        assertEq(uint160(Hooks.AFTER_DONATE_FLAG), 1 << 4);
        assertEq(uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG), 1 << 2);
        assertFalse(computedMask & uint160(Hooks.AFTER_INITIALIZE_FLAG) != 0, "AFTER_INITIALIZE must not be set - never used");
        assertFalse(computedMask & uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG) != 0, "AFTER_ADD_LIQUIDITY must not be set - beforeAddLiquidity alone is sufficient to gate");
        assertFalse(computedMask & uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG) != 0, "AFTER_REMOVE_LIQUIDITY must not be set");
        assertFalse(computedMask & uint160(Hooks.BEFORE_DONATE_FLAG) != 0, "donate is not used by this protocol");
        assertFalse(computedMask & uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) != 0, "afterSwap never returns a delta - it only verifies/calibrates, confirmed: Hooks.sol requires this flag be UNSET if AFTER_SWAP_FLAG is set and no delta is returned, or the address validation itself would reject the hook");
    }
}
