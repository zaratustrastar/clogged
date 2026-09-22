// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Position} from "v4-core/src/libraries/Position.sol";

/// @title ModifyLiquidityInAfterSwapProbe
/// @notice THE load-bearing probe for Architecture B. Answers one question on the REAL
///         Robinhood PoolManager:
///
///     Can PoolManager.modifyLiquidity() be called from inside afterSwap, during the SAME
///     unlock session, with its BalanceDeltas settled before the unlock closes?
///
///   No CLOG economics here at all - no taxes, no Registry, no ClogMarket. A failure in this
///   file is unambiguously a v4-platform fact, not a CLOG bug.
///
///   WHAT THE PINNED SOURCE ALREADY SAYS (v4-core v4.0.0, e50237c43811bd9b526eff40f26772152a42daba;
///   read directly, not assumed):
///
///     PoolManager.sol:148   modifyLiquidity is `onlyWhenUnlocked noDelegateCall` - there is NO
///                           reentrancy guard, and the lock is still open during afterSwap, so
///                           the call should be admissible.
///     PoolManager.sol:185+  _swap() completes BEFORE key.hooks.afterSwap() is invoked, so slot0
///                           is already final when afterSwap runs. The re-anchor must therefore
///                           re-shape liquidity around that price WITHOUT moving it.
///     PoolManager.sol:180   _accountPoolBalanceDelta(key, callerDelta, msg.sender) - a
///                           hook-initiated modifyLiquidity accrues its delta to the HOOK, which
///                           must then settle/take it itself.
///     Hooks.sol:170-174     modifier noSelfCall(IHooks self) { if (msg.sender != address(self)) { _; } }
///     Hooks.sol:194-199     beforeModifyLiquidity carries noSelfCall(self), so the hook's own
///                           modifyLiquidity does NOT re-enter its own add/remove gates.
///     PoolManager.sol:112   unlock() reverts CurrencyNotSettled if NonzeroDeltaCount != 0.
///
///   This probe exists to confirm all of that on-chain rather than on paper.
///
///   NO try/catch AROUND THE MODIFYLIQUIDITY CALLS. If the platform rejects them, this test
///   reverts with the real reason and fails loudly. The success flags are set only AFTER the
///   calls return, so they can never report success for a call that did not happen.
///
///   RUN:
///     forge test --profile v4 --fork-url $ROBINHOOD_RPC \
///       --match-path test-v4/genuine/ModifyLiquidityInAfterSwapProbe.t.sol -vvvv
contract ModifyLiquidityInAfterSwapProbeTest is Test, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    /// @dev AFTER_SWAP (1<<6) | BEFORE_REMOVE_LIQUIDITY (1<<9) | BEFORE_ADD_LIQUIDITY (1<<11)
    ///      = 0x40 | 0x200 | 0x800 = 0xA40. No *_RETURNS_DELTA bits: Hooks.isValidHookAddress
    ///      only constrains those, and the probe does not need them.
    uint160 constant HOOK_FLAGS = 0xA40;

    bytes32 constant SALT = bytes32(uint256(0xC106));

    /// @dev Token-only launch, mirroring the Klik shape found on-chain (init tick 184,216 sits
    ///      ABOVE tickUpper 184,200, so the position is 100% currency1 and holds zero ETH).
    int24 constant TICK_LOWER = 177_284;
    int24 constant TICK_UPPER = 191_148;
    int24 constant INIT_TICK = 191_200; // strictly above TICK_UPPER
    uint128 constant POSITION_LIQUIDITY = 1e23;

    ProbeToken token;
    ProbeHook hook;
    PoolKey key;
    PoolId poolId;

    // recorded by the unlock callback
    int128 public observedSwapAmount0;
    int128 public observedSwapAmount1;

    enum Step {
        AddInitialLiquidity,
        Swap
    }

    function setUp() public {
        vm.skip(bytes(vm.envOr("ROBINHOOD_RPC", string(""))).length == 0);

        token = new ProbeToken();

        // Place the hook at an address carrying HOOK_FLAGS in its low 14 bits.
        address hookAddr = address(uint160(0x4444 << 144) | HOOK_FLAGS);
        deployCodeTo("ModifyLiquidityInAfterSwapProbe.t.sol:ProbeHook", abi.encode(POOL_MANAGER), hookAddr);
        hook = ProbeHook(payable(hookAddr));

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO, // native ETH
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(hookAddr)
        });
        poolId = key.toId();

        POOL_MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(INIT_TICK));

        // Fund this contract (LP) and the hook (so it can settle any net re-anchor debt).
        token.mint(address(this), 2_000_000_000e18);
        token.mint(address(hook), 100_000_000e18);
        vm.deal(address(this), 100 ether);
        vm.deal(address(hook), 10 ether);

        POOL_MANAGER.unlock(abi.encode(Step.AddInitialLiquidity));
    }

    // ───────────────────────────────────────────── assertions ──

    /// @notice A genuine token-only protocol position exists, with zero ETH in it.
    /// @dev Per the corrected launch criteria: pool-wide active liquidity may legitimately be
    ///      ZERO before the first buy crosses tickUpper (exactly as the live Klik pool is), so
    ///      this asserts POSITION liquidity, not getLiquidity().
    function test_1_initialPosition_isTokenOnly_withNonzeroPositionLiquidity() public view {
        bytes32 posKey = Position.calculatePositionKey(address(this), TICK_LOWER, TICK_UPPER, SALT);
        uint128 posLiq = POOL_MANAGER.getPositionLiquidity(poolId, posKey);
        assertEq(posLiq, POSITION_LIQUIDITY, "protocol position liquidity missing");
        assertEq(address(POOL_MANAGER).balance, 0, "launch must require ZERO protocol ETH");
        assertGt(token.balanceOf(address(POOL_MANAGER)), 0, "position must hold token");

        (, int24 tick,,) = POOL_MANAGER.getSlot0(poolId);
        assertGt(tick, TICK_UPPER, "price must start above the range (token-only)");
    }

    /// @notice One genuine swap that enters the range, then the re-anchor inside afterSwap.
    /// @dev No try/catch: if modifyLiquidity from afterSwap is rejected by the platform, this
    ///      reverts here with the real reason.
    function test_2_genuineSwap_thenReanchorInsideAfterSwap() public {
        // Pass 1: hook has no position of its own yet -> mint only.
        POOL_MANAGER.unlock(abi.encode(Step.Swap));
        assertTrue(hook.mintSucceeded(), "first re-anchor mint did not complete");
        assertFalse(hook.burnAttempted(), "nothing should have been burnable on pass 1");

        // Pass 2: the hook now owns a position, so this exercises burn + re-mint.
        POOL_MANAGER.unlock(abi.encode(Step.Swap));
        assertTrue(hook.burnAttempted(), "pass 2 should have attempted a burn");

        // --- the swap itself was genuine ---
        assertLt(observedSwapAmount0, 0, "core Swap amount0 must be negative (ETH paid in)");
        assertGt(observedSwapAmount1, 0, "core Swap amount1 must be positive (token paid out)");

        // --- afterSwap ran, and both liquidity modifications completed ---
        assertTrue(hook.afterSwapRan(), "afterSwap never ran");
        assertTrue(hook.burnSucceeded(), "burn inside afterSwap did not complete");
        assertTrue(hook.mintSucceeded(), "replacement mint inside afterSwap did not complete");

        // --- the re-anchor must not disturb the canonical price ---
        assertEq(
            hook.sqrtPriceBeforeReanchor(), hook.sqrtPriceAfterReanchor(), "re-anchor moved slot0"
        );

        // --- v4 noSelfCall must have skipped the hook's own add/remove gates ---
        assertEq(hook.addLiquidityGateCalls(), 0, "hook's own mint re-entered beforeAddLiquidity");
        assertEq(hook.removeLiquidityGateCalls(), 0, "hook's own burn re-entered beforeRemoveLiquidity");

        // --- the outer unlock closed, so every currency was settled ---
        // (reaching this line at all proves it: unlock() reverts CurrencyNotSettled otherwise)
        assertTrue(hook.reanchorCompleted(), "re-anchor did not run to completion");

        // --- the replacement position exists with the intended range and liquidity ---
        bytes32 newKey =
            Position.calculatePositionKey(address(hook), hook.newTickLower(), hook.newTickUpper(), SALT);
        assertEq(
            POOL_MANAGER.getPositionLiquidity(poolId, newKey),
            hook.newLiquidity(),
            "replacement position missing or wrong size"
        );
        assertGt(hook.newLiquidity(), 0, "replacement liquidity must be nonzero");

        // --- after the buy crossed tickUpper, the expected liquidity is active ---
        (, int24 tick,,) = POOL_MANAGER.getSlot0(poolId);
        assertLt(tick, TICK_UPPER, "swap should have crossed into the range");
        assertGt(POOL_MANAGER.getLiquidity(poolId), 0, "liquidity must be active after the first buy");
    }

    // ───────────────────────────────────────── unlock callback ──

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(POOL_MANAGER), "not PM");
        Step step = abi.decode(data, (Step));

        if (step == Step.AddInitialLiquidity) {
            (BalanceDelta d,) = POOL_MANAGER.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
                    liquidityDelta: int256(uint256(POSITION_LIQUIDITY)),
                    salt: SALT
                }),
                ""
            );
            _settleDelta(d);
        } else {
            BalanceDelta d = POOL_MANAGER.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true, // ETH -> token
                    amountSpecified: -0.5 ether, // exact input
                    sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                ""
            );
            observedSwapAmount0 = d.amount0();
            observedSwapAmount1 = d.amount1();
            _settleDelta(d);
        }
        return "";
    }

    /// @dev Settle this contract's own deltas. Negative = we owe the manager.
    function _settleDelta(BalanceDelta d) internal {
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();

        if (a0 < 0) {
            POOL_MANAGER.settle{value: uint256(uint128(-a0))}();
        } else if (a0 > 0) {
            POOL_MANAGER.take(key.currency0, address(this), uint256(uint128(a0)));
        }

        if (a1 < 0) {
            POOL_MANAGER.sync(key.currency1);
            token.transfer(address(POOL_MANAGER), uint256(uint128(-a1)));
            POOL_MANAGER.settle();
        } else if (a1 > 0) {
            POOL_MANAGER.take(key.currency1, address(this), uint256(uint128(a1)));
        }
    }

    receive() external payable {}
}

/// @dev Minimal ERC20. Deliberately trivial - the probe is about PoolManager, not the token.
contract ProbeToken {
    string public constant name = "Probe";
    string public constant symbol = "PRB";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
        emit Transfer(address(0), to, amt);
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        emit Transfer(msg.sender, to, amt);
        return true;
    }

    function approve(address s, uint256 amt) external returns (bool) {
        allowance[msg.sender][s] = amt;
        emit Approval(msg.sender, s, amt);
        return true;
    }

    function transferFrom(address f, address t, uint256 amt) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= amt;
        balanceOf[f] -= amt;
        balanceOf[t] += amt;
        emit Transfer(f, t, amt);
        return true;
    }
}

/// @dev Instrumented hook. Contains NO CLOG economics - it exists only to attempt the re-anchor
///      from afterSwap and record what the platform did.
contract ProbeHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;

    bytes32 constant SALT = bytes32(uint256(0xC106));

    bool public afterSwapRan;
    bool public burnAttempted;
    bool public burnSucceeded;
    bool public mintSucceeded;
    bool public reanchorCompleted;
    uint256 public addLiquidityGateCalls;
    uint256 public removeLiquidityGateCalls;
    uint160 public sqrtPriceBeforeReanchor;
    uint160 public sqrtPriceAfterReanchor;
    int24 public newTickLower;
    int24 public newTickUpper;
    uint128 public newLiquidity;

    // the position this hook will burn - seeded by the test's LP, re-minted under the hook
    int24 constant OLD_LOWER = 177_284;
    int24 constant OLD_UPPER = 191_148;

    constructor(IPoolManager pm) {
        poolManager = pm;
    }

    /// @dev Per Hooks.sol:194-199 these should NEVER fire for the hook's own modifyLiquidity
    ///      (noSelfCall). Counting instead of reverting so the test can distinguish
    ///      "gate fired" from "gate reverted the whole tx".
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        returns (bytes4)
    {
        addLiquidityGateCalls++;
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external returns (bytes4) {
        removeLiquidityGateCalls++;
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice The actual probe. NO try/catch - a platform rejection reverts the whole swap.
    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        require(msg.sender == address(poolManager), "not PM");
        afterSwapRan = true;

        PoolId id = key.toId();
        (uint160 sqrtBefore, int24 tick,,) = poolManager.getSlot0(id);
        sqrtPriceBeforeReanchor = sqrtBefore;

        // 1) Burn the hook's own position if one exists. The seed position belongs to the test
        //    LP, not the hook, so pass 1 has nothing to burn and only mints. Pass 2 exercises
        //    the burn. The test therefore swaps TWICE; burnSucceeded stays false until a burn
        //    has genuinely executed, so it can never report success for a call that never ran.
        BalanceDelta net = BalanceDelta.wrap(0);
        uint128 existing;
        if (newLiquidity != 0) {
            bytes32 own = Position.calculatePositionKey(address(this), newTickLower, newTickUpper, SALT);
            existing = poolManager.getPositionLiquidity(id, own);
        }

        if (existing > 0) {
            burnAttempted = true;
            (BalanceDelta burnDelta,) = poolManager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: newTickLower,
                    tickUpper: newTickUpper,
                    liquidityDelta: -int256(uint256(existing)),
                    salt: SALT
                }),
                ""
            );
            net = net + burnDelta;
            burnSucceeded = true; // only reachable if modifyLiquidity actually returned
        }

        // 2) Mint the replacement AROUND the current price, without moving it.
        int24 lo = tick - 2_000;
        int24 hi = tick + 2_000;
        (BalanceDelta mintDelta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lo,
                tickUpper: hi,
                liquidityDelta: int256(uint256(uint128(1e20))),
                salt: SALT
            }),
            ""
        );
        net = net + mintDelta;
        mintSucceeded = true;

        newTickLower = lo;
        newTickUpper = hi;
        newLiquidity = 1e20;

        // 3) Settle every delta these modifications generated, inside the SAME unlock.
        _settle(key, net);

        (uint160 sqrtAfter,,,) = poolManager.getSlot0(id);
        sqrtPriceAfterReanchor = sqrtAfter;

        reanchorCompleted = true;
        return (IHooks.afterSwap.selector, int128(0));
    }

    function _settle(PoolKey calldata key, BalanceDelta d) internal {
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();

        if (a0 < 0) {
            poolManager.settle{value: uint256(uint128(-a0))}();
        } else if (a0 > 0) {
            poolManager.take(key.currency0, address(this), uint256(uint128(a0)));
        }

        if (a1 < 0) {
            poolManager.sync(key.currency1);
            ProbeToken(Currency.unwrap(key.currency1)).transfer(address(poolManager), uint256(uint128(-a1)));
            poolManager.settle();
        } else if (a1 > 0) {
            poolManager.take(key.currency1, address(this), uint256(uint128(a1)));
        }
    }

    receive() external payable {}
}
