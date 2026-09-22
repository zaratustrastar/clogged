// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @title ModifyLiquidityInAfterSwapProbe
/// @notice RUN THIS FIRST. The entire Architecture-B design depends on one unproven property:
///
///     Can PoolManager.modifyLiquidity() be called from inside afterSwap, during the SAME
///     unlock session, on the Robinhood-pinned v4 implementation?
///
///   If it reverts, re-enters, corrupts the swap delta accounting, or moves slot0, then
///   ClogGenuineLiquidityHook as written is INVALID and the design must fall back to a deferred
///   re-anchor (next-trade lazy re-anchor, or a permissionless keeper call between trades).
///
///   This probe is deliberately standalone: it uses a minimal hook with no CLOG economics at
///   all, so a failure here is unambiguously a v4-platform fact and not a CLOG bug.
///
///   Run against the REAL Robinhood PoolManager, not a local deployment:
///     forge test --profile v4 --fork-url $ROBINHOOD_RPC \
///       --match-path test-v4/genuine/ModifyLiquidityInAfterSwapProbe.t.sol -vvvv
contract ModifyLiquidityInAfterSwapProbe is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    ProbeHook hook;

    function setUp() public {
        // Requires ROBINHOOD_RPC. Skipped locally by design - see PROTOTYPE notes.
        vm.skip(bytes(vm.envOr("ROBINHOOD_RPC", string(""))).length == 0);
    }

    /// @notice Probe 1 - does modifyLiquidity in afterSwap revert?
    function test_modifyLiquidity_inside_afterSwap_doesNotRevert() public {
        // Deploy ProbeHook at a mined address carrying AFTER_SWAP | BEFORE_SWAP flags, seed a
        // token-only position, execute one ordinary swap, and assert afterSwap's burn+mint
        // completed. ProbeHook records success/failure rather than bubbling, so the assertion
        // message distinguishes "reverted" from "never called".
        assertTrue(hook.afterSwapRan(), "afterSwap never ran");
        assertTrue(hook.modifyLiquiditySucceeded(), "modifyLiquidity inside afterSwap reverted");
    }

    /// @notice Probe 2 - does the re-anchor disturb slot0?
    /// @dev The core swap must leave slot0 canonical; the burn+mint must re-shape liquidity
    ///      AROUND that price without moving it. Any drift here invalidates the "no calibration
    ///      swap" claim, which is the entire point of this architecture.
    function test_reanchor_doesNotMove_slot0() public {
        assertEq(hook.sqrtPriceBeforeReanchor(), hook.sqrtPriceAfterReanchor(), "re-anchor moved slot0");
    }

    /// @notice Probe 3 - does the hook's own modifyLiquidity re-enter beforeAddLiquidity?
    /// @dev v4's noSelfCall should skip the callback when the hook is its own caller. If it does
    ///      NOT, the liquidity gating in ClogGenuineLiquidityHook would reject the protocol's own
    ///      re-anchor and every trade would revert.
    function test_selfCall_skips_liquidityGating() public {
        assertEq(hook.addLiquidityCallbackCount(), 0, "hook's own modifyLiquidity re-entered the gate");
    }

    /// @notice Probe 4 - are deltas from afterSwap-time modifyLiquidity settled correctly?
    /// @dev The burn returns tokens to the hook and the mint takes them back. The net must be
    ///      settleable within the same unlock, leaving no unresolved currency delta, or
    ///      PoolManager will revert with CurrencyNotSettled at the end of the unlock.
    function test_reanchor_leavesNoUnsettledDelta() public {
        assertTrue(hook.unlockCompleted(), "unlock did not complete - CurrencyNotSettled likely");
    }
}

/// @dev Minimal instrumented hook. No CLOG economics - this probes v4 platform behaviour only.
contract ProbeHook {
    bool public afterSwapRan;
    bool public modifyLiquiditySucceeded;
    bool public unlockCompleted;
    uint256 public addLiquidityCallbackCount;
    uint160 public sqrtPriceBeforeReanchor;
    uint160 public sqrtPriceAfterReanchor;

    // Implementation intentionally omitted from this prototype commit: it must be written
    // against the pinned v4-core in lib/, and the point of this file is to pin down WHAT has to
    // be proven before any of ClogGenuineLiquidityHook is trusted. Filling this in is the first
    // task on clogrun.
}
