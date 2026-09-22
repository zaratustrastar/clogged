// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NoopEligibility} from "./mocks/NoopEligibility.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ClogV4Hook} from "../src-v4/ClogV4Hook.sol";
import {ClogMarket} from "../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "./mocks/MinimalMockToken.sol";
import {MockTickerNFT} from "../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../src/RewardVault.sol";

/// @notice registerMarket must not rely on the launch initializer being honest - it validates
///         the actual PoolKey/market relationship directly, so even an AUTHORIZED but malformed
///         call (a real bug in the launch flow, not merely an external attacker - see
///         CrossMarketIsolation.t.sol for that case) is rejected. Every test here calls
///         registerMarket as the genuine, authorized launchInitializer.
contract MarketRegistrationTest is Test {
    PoolManager manager;
    ClogV4Hook hook;
    RewardVault rewardVault;

    address constant HOOK_ADDRESS = address(0x2088); // see ClogV4HookBuySell.t.sol for the flag derivation
    address tickerOwner = makeAddr("tickerOwner");
    address multisig = makeAddr("multisig");
    MockTickerNFT tickerNFT;
    uint256 constant TICKER_TOKEN_ID = 1;
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant VIRTUAL_TOKEN_SEED = 1_800_000_000e18;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000;
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;

    function setUp() public {
        manager = new PoolManager(address(this));
        ClogV4Hook impl = new ClogV4Hook(IPoolManager(address(manager)), address(this));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = ClogV4Hook(HOOK_ADDRESS);
        rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS);
        hook.setRewardVault(address(rewardVault));
        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(TICKER_TOKEN_ID, tickerOwner);
    }

    function _realMarketAndToken() internal returns (ClogMarket m, MinimalMockToken t) {
        t = new MinimalMockToken();
        m = new ClogMarket(HOOK_ADDRESS, address(t), address(tickerNFT), TICKER_TOKEN_ID, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS, address(new NoopEligibility()));
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
        ClogMarket misconfiguredMarket = new ClogMarket(differentHook, address(t), address(tickerNFT), TICKER_TOKEN_ID, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS, address(new NoopEligibility()));

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

    // ── Deployment-initialization gate: registerMarket must reject until rewardVault is set ──

    function test_registerMarket_revertsIfRewardVaultNotConfigured() public {
        // A fresh hook that has NOT had setRewardVault called yet at all.
        address freshHookAddress = address(0x3099);
        ClogV4Hook freshImpl = new ClogV4Hook(IPoolManager(address(manager)), address(this));
        vm.etch(freshHookAddress, address(freshImpl).code);
        ClogV4Hook freshHook = ClogV4Hook(freshHookAddress);

        MinimalMockToken t = new MinimalMockToken();
        ClogMarket m = new ClogMarket(freshHookAddress, address(t), address(tickerNFT), TICKER_TOKEN_ID, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS, address(new NoopEligibility()));
        PoolKey memory key =
            PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(t)), fee: 0, tickSpacing: 60, hooks: IHooks(freshHookAddress)});

        vm.expectRevert(bytes("reward vault not configured"));
        freshHook.registerMarket(key, address(m));
    }

    // ── setRewardVault's own one-time-initialization semantics ───────────────────────────────

    function test_setRewardVault_onlyLaunchInitializer_reverts() public {
        address notInitializer = makeAddr("notInitializer");
        vm.prank(notInitializer);
        vm.expectRevert(bytes("not launch initializer"));
        hook.setRewardVault(address(rewardVault));
    }

    function test_setRewardVault_zeroAddress_reverts() public {
        address freshHookAddress = address(0x3099);
        ClogV4Hook freshImpl = new ClogV4Hook(IPoolManager(address(manager)), address(this));
        vm.etch(freshHookAddress, address(freshImpl).code);
        vm.expectRevert(bytes("zero reward vault"));
        ClogV4Hook(freshHookAddress).setRewardVault(address(0));
    }

    function test_setRewardVault_callableExactlyOnce_secondCallReverts() public {
        // `hook` (HOOK_ADDRESS) already had setRewardVault called once in setUp() - a second
        // call, even with a different, otherwise-valid address, must revert: this is one-time
        // deployment initialization, never ongoing upgradeability.
        RewardVault anotherVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS);
        vm.expectRevert(bytes("already configured"));
        hook.setRewardVault(address(anotherVault));

        // The original configuration must be completely unchanged after the reverted attempt.
        assertEq(hook.rewardVault(), address(rewardVault), "rewardVault must remain exactly what setUp() originally configured");
    }
}
