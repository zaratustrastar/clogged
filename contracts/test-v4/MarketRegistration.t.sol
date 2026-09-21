// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ClogV4Hook} from "../src-v4/ClogV4Hook.sol";
import {ClogMarket} from "../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "./mocks/MinimalMockToken.sol";

/// @notice registerMarket must not rely on the launch initializer being honest - it validates
///         the actual PoolKey/market relationship directly, so even an AUTHORIZED but malformed
///         call (a real bug in the launch flow, not merely an external attacker - see
///         CrossMarketIsolation.t.sol for that case) is rejected. Every test here calls
///         registerMarket as the genuine, authorized launchInitializer.
contract MarketRegistrationTest is Test {
    PoolManager manager;
    ClogV4Hook hook;

    address constant HOOK_ADDRESS = address(0x2088); // see ClogV4HookBuySell.t.sol for the flag derivation
    address tickerOwner = makeAddr("tickerOwner");
    address multisig = makeAddr("multisig");
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant VIRTUAL_TOKEN_SEED = 1_800_000_000e18;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000;
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;

    function setUp() public {
        manager = new PoolManager(address(this));
        ClogV4Hook impl = new ClogV4Hook(IPoolManager(address(manager)), address(this));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = ClogV4Hook(HOOK_ADDRESS);
    }

    function _realMarketAndToken() internal returns (ClogMarket m, MinimalMockToken t) {
        t = new MinimalMockToken();
        m = new ClogMarket(HOOK_ADDRESS, address(t), tickerOwner, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS);
    }

    // ── Authorized caller, wrong token paired against a real market ─────────────────────────

    function test_authorizedCaller_wrongTokenPairedWithRealMarket_reverts() public {
        (ClogMarket m,) = _realMarketAndToken();
        MinimalMockToken wrongToken = new MinimalMockToken(); // NOT m.token()

        PoolKey memory keyWithWrongToken =
            PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(wrongToken)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});

        // Called by the genuine, authorized launchInitializer (address(this)) - this is a bug
        // in the launch flow's own construction, not an external attack, and must still fail.
        vm.expectRevert(bytes("PoolKey currency1 must be exactly the market's own token"));
        hook.registerMarket(keyWithWrongToken, address(m));
    }

    // ── Authorized caller, PoolKey naming a different hook ───────────────────────────────────

    function test_authorizedCaller_wrongHookInPoolKey_reverts() public {
        (ClogMarket m, MinimalMockToken t) = _realMarketAndToken();
        address someOtherHookAddress = address(0x9999);

        PoolKey memory keyWithWrongHook =
            PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(t)), fee: 0, tickSpacing: 60, hooks: IHooks(someOtherHookAddress)});

        vm.expectRevert(bytes("PoolKey hook mismatch"));
        hook.registerMarket(keyWithWrongHook, address(m));
    }

    // ── Authorized caller, market whose OWN hook() points elsewhere ──────────────────────────

    function test_authorizedCaller_marketPointingAtDifferentHook_reverts() public {
        MinimalMockToken t = new MinimalMockToken();
        address differentHook = address(0x9999);
        // A market constructed pointing at a DIFFERENT hook than the one performing registration -
        // its own onlyHook modifier would reject every real trade call anyway, but this must be
        // caught at registration time, not discovered later as a silently-dead market.
        ClogMarket misconfiguredMarket = new ClogMarket(differentHook, address(t), tickerOwner, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS);

        PoolKey memory key =
            PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(t)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});

        vm.expectRevert(bytes("market's own hook must be this hook"));
        hook.registerMarket(key, address(misconfiguredMarket));
    }

    // ── Same market registered to a second PoolKey ───────────────────────────────────────────

    function test_sameMarketRegisteredToSecondPoolKey_reverts() public {
        (ClogMarket m, MinimalMockToken t) = _realMarketAndToken();
        PoolKey memory firstKey =
            PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(t)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});
        hook.registerMarket(firstKey, address(m));

        // A second, DIFFERENT PoolKey for the exact same market (different fee tier, say) -
        // one market must never be reachable through two different pools.
        PoolKey memory secondKey =
            PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(t)), fee: 3000, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});

        vm.expectRevert(bytes("market already registered to a different pool"));
        hook.registerMarket(secondKey, address(m));
    }

    // ── The correct, well-formed relationship succeeds ───────────────────────────────────────

    function test_correctRelationship_succeeds() public {
        (ClogMarket m, MinimalMockToken t) = _realMarketAndToken();
        PoolKey memory key =
            PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(t)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});

        hook.registerMarket(key, address(m));

        assertEq(hook.marketOf(key.toId()), address(m), "marketOf must resolve to the registered market");
        assertEq(PoolId.unwrap(hook.poolOf(address(m))), PoolId.unwrap(key.toId()), "poolOf must resolve back to the exact same pool - the reverse relationship must hold");
    }
}
