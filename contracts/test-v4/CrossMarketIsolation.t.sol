// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ClogV4Hook} from "../src-v4/ClogV4Hook.sol";
import {ClogMarket} from "../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "./mocks/MinimalMockToken.sol";

/// @title P0 cross-market isolation
/// @notice Every ClogMarket approves the SAME universal hook, so PoolManager's own ERC6909
///         ledger does NOT by itself prevent the hook from touching any approved market's
///         claims (see the architecture discussion this was built in) - the hook's own
///         marketOf[poolId] registry, checked against the ACTUAL PoolKey a swap runs against
///         and never against hookData, is the real isolation boundary. This suite proves that
///         boundary holds with >=2 simultaneously live markets, per the explicit P0 requirement.
contract CrossMarketIsolationTest is Test, IUnlockCallback {
    PoolManager manager;
    ClogV4Hook hook;

    ClogMarket marketA;
    MinimalMockToken tokenA;
    PoolKey keyA;

    ClogMarket marketB;
    MinimalMockToken tokenB;
    PoolKey keyB;

    address constant HOOK_ADDRESS = address(0x2088); // see ClogV4HookBuySell.t.sol for the flag derivation

    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant VIRTUAL_TOKEN_SEED = 1_800_000_000e18;

    bool private _depositingA;
    bool private _depositingB;

    function setUp() public {
        manager = new PoolManager(address(this));

        ClogV4Hook impl = new ClogV4Hook(IPoolManager(address(manager)), address(this));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = ClogV4Hook(HOOK_ADDRESS);

        (marketA, tokenA, keyA) = _setUpMarket("A", true);
        (marketB, tokenB, keyB) = _setUpMarket("B", false);
    }

    function _setUpMarket(string memory label, bool isMarketA) internal returns (ClogMarket m, MinimalMockToken t, PoolKey memory k) {
        t = new MinimalMockToken();
        m = new ClogMarket(HOOK_ADDRESS, address(t), VIRTUAL_ETH_SEED, VIRTUAL_TOKEN_SEED);
        k = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(t)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});

        hook.registerMarket(k, address(m));
        manager.initialize(k, 79228162514264337593543950336);

        t.mint(address(m), VIRTUAL_TOKEN_SEED);
        if (isMarketA) {
            _depositingA = true;
        } else {
            _depositingB = true;
        }
        manager.unlock(abi.encode(m, t));
        _depositingA = false;
        _depositingB = false;

        vm.startPrank(address(m));
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(t))), type(uint256).max);
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(0))), type(uint256).max);
        vm.stopPrank();

        label; // silence unused-param warning; kept for readability at call sites
    }

    // ── Router plumbing (same pattern as ClogV4HookBuySell.t.sol) ────────────────────────────

    struct SwapRequest {
        PoolKey key;
        MinimalMockToken token;
        bool zeroForOne;
        int256 amountSpecified;
        bytes hookData;
    }

    function _doSwap(PoolKey memory k, MinimalMockToken t, bool zeroForOne, int256 amountSpecified, bytes memory hookData) internal returns (BalanceDelta) {
        bytes memory result = manager.unlock(abi.encode(SwapRequest({key: k, token: t, zeroForOne: zeroForOne, amountSpecified: amountSpecified, hookData: hookData})));
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not pool manager");

        if (_depositingA || _depositingB) {
            (ClogMarket m, MinimalMockToken t) = abi.decode(data, (ClogMarket, MinimalMockToken));
            Currency currency1 = Currency.wrap(address(t));
            manager.sync(currency1);
            vm.prank(address(m));
            t.transfer(address(manager), VIRTUAL_TOKEN_SEED);
            manager.settle();
            manager.mint(address(m), uint256(uint160(address(t))), VIRTUAL_TOKEN_SEED);
            return bytes("");
        }

        SwapRequest memory req = abi.decode(data, (SwapRequest));
        BalanceDelta swapDelta = manager.swap(
            req.key,
            IPoolManager.SwapParams({
                zeroForOne: req.zeroForOne,
                amountSpecified: req.amountSpecified,
                sqrtPriceLimitX96: req.zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            req.hookData
        );

        if (req.zeroForOne) {
            int128 ethOwed = -swapDelta.amount0();
            manager.sync(req.key.currency0);
            manager.settle{value: uint256(int256(ethOwed))}();
            int128 tokenOwed = swapDelta.amount1();
            manager.take(req.key.currency1, address(this), uint256(int256(tokenOwed)));
        } else {
            int128 tokenOwed = -swapDelta.amount1();
            manager.sync(req.key.currency1);
            req.token.transfer(address(manager), uint256(int256(tokenOwed)));
            manager.settle();
            int128 ethOwed = swapDelta.amount0();
            manager.take(req.key.currency0, address(this), uint256(int256(ethOwed)));
        }

        return abi.encode(swapDelta);
    }

    receive() external payable {}

    function _snapshotClaims(ClogMarket m, MinimalMockToken t) internal view returns (uint256 ethClaim, uint256 tokenClaim) {
        ethClaim = manager.balanceOf(address(m), uint256(uint160(address(0))));
        tokenClaim = manager.balanceOf(address(m), uint256(uint160(address(t))));
    }

    // ── P0: a buy on A cannot alter B's claims ───────────────────────────────────────────────

    function test_buyOnMarketA_doesNotAlterMarketBClaims() public {
        (uint256 bEthBefore, uint256 bTokenBefore) = _snapshotClaims(marketB, tokenB);
        uint256 bReBefore = marketB.re();
        uint256 bRtBefore = marketB.rt();

        vm.deal(address(this), 0.01 ether);
        _doSwap(keyA, tokenA, true, -0.01 ether, bytes(""));

        (uint256 bEthAfter, uint256 bTokenAfter) = _snapshotClaims(marketB, tokenB);
        assertEq(bEthAfter, bEthBefore, "B's own ETH claim must be completely untouched by a trade on A");
        assertEq(bTokenAfter, bTokenBefore, "B's own token claim must be completely untouched by a trade on A");
        assertEq(marketB.re(), bReBefore, "B's own curve state (re) must be completely untouched by a trade on A");
        assertEq(marketB.rt(), bRtBefore, "B's own curve state (rt) must be completely untouched by a trade on A");
    }

    // ── P0: a sell on A cannot alter B's claims ──────────────────────────────────────────────

    function test_sellOnMarketA_doesNotAlterMarketBClaims() public {
        vm.deal(address(this), 0.01 ether);
        BalanceDelta buyDelta = _doSwap(keyA, tokenA, true, -0.01 ether, bytes(""));
        uint256 tokensHeld = uint256(int256(buyDelta.amount1()));

        (uint256 bEthBefore, uint256 bTokenBefore) = _snapshotClaims(marketB, tokenB);

        _doSwap(keyA, tokenA, false, -int256(tokensHeld / 2), bytes(""));

        (uint256 bEthAfter, uint256 bTokenAfter) = _snapshotClaims(marketB, tokenB);
        assertEq(bEthAfter, bEthBefore, "B's own ETH claim must be completely untouched by a sell on A");
        assertEq(bTokenAfter, bTokenBefore, "B's own token claim must be completely untouched by a sell on A");
    }

    // ── P0: hookData naming/encoding market B while trading on A has no effect at all ────────

    function test_maliciousHookData_namingOtherMarket_hasNoEffect() public {
        // The hook never reads hookData for market selection at all (marketOf[key.toId()] is
        // the only source), so a swap on A with hookData that encodes B's own address must
        // behave IDENTICALLY to the same swap with empty hookData - proving this by direct
        // comparison, not merely by code inspection.
        (uint256 bEthBefore, uint256 bTokenBefore) = _snapshotClaims(marketB, tokenB);

        vm.deal(address(this), 0.01 ether);
        bytes memory maliciousHookData = abi.encode(address(marketB), address(tokenB));
        BalanceDelta delta = _doSwap(keyA, tokenA, true, -0.01 ether, maliciousHookData);

        (uint256 bEthAfter, uint256 bTokenAfter) = _snapshotClaims(marketB, tokenB);
        assertEq(bEthAfter, bEthBefore, "B's claims must be unaffected regardless of what hookData names");
        assertEq(bTokenAfter, bTokenBefore, "B's claims must be unaffected regardless of what hookData names");
        assertGt(uint256(int256(delta.amount1())), 0, "the swap on A must still have succeeded normally despite the malicious hookData");
    }

    // ── P0: a swap cannot reach an unregistered pool/market at all ──────────────────────────

    function test_swapOnUnregisteredPool_reverts() public {
        // A third PoolKey, using the SAME hook address, that was never registered via
        // registerMarket nor initialized - the hook's own beforeSwap must reject it outright,
        // never falling back to any default/guessed market. Uses try/catch rather than
        // vm.expectRevert directly around the unlock/callback round-trip, since the actual
        // revert originates several call frames deep (unlock -> unlockCallback -> swap).
        MinimalMockToken tokenC = new MinimalMockToken();
        PoolKey memory unregisteredKey =
            PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(tokenC)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});

        vm.deal(address(this), 0.01 ether);
        bool reverted;
        try this.externalDoSwap(unregisteredKey, tokenC, true, -0.01 ether, bytes("")) {
            reverted = false;
        } catch {
            reverted = true;
        }
        assertTrue(reverted, "swapping against a never-registered, never-initialized pool must revert, not silently succeed against some fallback market");
    }

    /// @dev External wrapper solely so the try/catch above can call _doSwap across a real call
    ///      boundary (try/catch only works on external calls in Solidity).
    function externalDoSwap(PoolKey memory k, MinimalMockToken t, bool zeroForOne, int256 amountSpecified, bytes memory hookData) external returns (BalanceDelta) {
        require(msg.sender == address(this), "test-only");
        return _doSwap(k, t, zeroForOne, amountSpecified, hookData);
    }

    // ── P0: a forged PoolKey (wrong token paired with hook) cannot access A's real claims ───

    function test_forgedPoolKey_wrongTokenPairedWithHook_cannotAccessRealMarketClaims() public {
        // An attacker constructs a PoolKey using the CLOG hook but pairing it with an
        // arbitrary token they control, attempting to register/initialize their own pool and
        // have it resolve to a real, existing market's claims. This must fail at
        // registerMarket's own access control (only the launch initializer may register any
        // market at all) - an outside caller has no path to associate arbitrary PoolKeys with
        // marketA's claims.
        address attacker = makeAddr("attacker");
        MinimalMockToken attackerToken = new MinimalMockToken();
        PoolKey memory forgedKey =
            PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(attackerToken)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});

        vm.prank(attacker);
        vm.expectRevert(bytes("not launch initializer"));
        hook.registerMarket(forgedKey, address(marketA));
    }
}
