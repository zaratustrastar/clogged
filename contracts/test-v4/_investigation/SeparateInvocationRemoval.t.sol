// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ClogV4Hook} from "../../src-v4/ClogV4Hook.sol";
import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "../mocks/MinimalMockToken.sol";
import {MockTickerNFT} from "../../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {SentinelLiquidityProbe} from "./fixtures/SentinelLiquidityProbeV1.sol";
import {SentinelLiquidityHelper} from "./fixtures/SentinelLiquidityHelperV1.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Proves the FIXED CREATE2 prediction (using the deterministic deployment proxy as
///         the "deployer" parameter, not the broadcasting EOA - see
///         test-v4/_investigation/BroadcastCreate2Check.t.sol for the underlying empirical
///         confirmation) actually works end to end: a SEPARATE, LATER instance of the exact
///         same script contract - simulating a genuinely separate `forge script` invocation,
///         sharing no state with the first beyond the live chain itself - computes the SAME
///         helper address and can locate and fully remove the exact position the first
///         invocation created.
///
/// @dev Builds real ClogV4Hook/ClogMarket/RewardVault fixtures and vm.etch's them onto the
///      EXACT hardcoded live addresses SentinelLiquidityProbe uses, and sets the local chain id
///      to match (4663), so the real, unmodified script contract can run its real setUp(),
///      addSentinel(), and removeSentinel() functions directly - not a rewritten copy of their
///      logic.
contract SeparateInvocationRemovalTest is Test {
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER_ADDR = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant CANARY_TOKEN_ADDR = 0xD9772c6Ac0811064C8b521fa8B1832ac81cD0DE8;
    address constant HOOK_ADDR = 0xB1232678cEBA3292e915AB834342aD869F042088;
    address constant DEPLOYER = 0x234fA20a83a88Db61f894890df7749A3fAF4dAEa;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 constant TICKER_TOKEN_ID = 1;
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000;
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;

    ClogMarket market;
    PoolKey key;
    bool private _depositing;

    function setUp() public {
        vm.chainId(4663);

        // Deploy real fixtures elsewhere, then etch their bytecode onto the exact hardcoded
        // live addresses the script itself uses - storage at those addresses starts empty,
        // matching a freshly-deployed contract's own initial state.
        // PoolManager inherits NoDelegateCall, which bakes in address(this) as an immutable at
        // construction time - vm.etch-ing its bytecode onto a different address would leave
        // that immutable permanently mismatched, breaking every call. deployCodeTo instead
        // runs the real constructor AT the target address, setting immutables correctly.
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), POOL_MANAGER_ADDR);
        IPoolManager manager = IPoolManager(POOL_MANAGER_ADDR);

        MinimalMockToken realToken = new MinimalMockToken();
        vm.etch(CANARY_TOKEN_ADDR, address(realToken).code);
        MinimalMockToken token = MinimalMockToken(CANARY_TOKEN_ADDR);

        ClogV4Hook realHook = new ClogV4Hook(manager, address(this));
        vm.etch(HOOK_ADDR, address(realHook).code);
        ClogV4Hook hook = ClogV4Hook(HOOK_ADDR);

        RewardVault rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDR);
        hook.setRewardVault(address(rewardVault));

        MockTickerNFT tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(TICKER_TOKEN_ID, makeAddr("tickerOwner"));

        market = new ClogMarket(HOOK_ADDR, CANARY_TOKEN_ADDR, address(tickerNFT), TICKER_TOKEN_ID, makeAddr("multisig"), VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS, address(new NoopEligibility()));

        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(CANARY_TOKEN_ADDR), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDR)});
        hook.registerMarket(key, address(market));
        manager.initialize(key, 79228162514264337593543950336); // matches the canary's own reported 1:1 legacy price

        token.mint(address(market), PHYSICAL_TOKEN_SUPPLY);
        _depositing = true;
        manager.unlock(bytes(""));
        _depositing = false;

        vm.startPrank(address(market));
        manager.approve(HOOK_ADDR, uint256(uint160(CANARY_TOKEN_ADDR)), type(uint256).max);
        manager.approve(HOOK_ADDR, uint256(uint160(address(0))), type(uint256).max);
        vm.stopPrank();

        vm.deal(DEPLOYER, 100 ether);
        token.mint(DEPLOYER, 1_000_000e18);

        require(CREATE2_DEPLOYER.code.length > 0, "sanity: this test's own Foundry EVM must have the deterministic deployment proxy pre-seeded, matching what the live chain is expected to have");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(_depositing, "unexpected callback");
        IPoolManager manager = IPoolManager(POOL_MANAGER_ADDR);
        manager.sync(key.currency1);
        vm.prank(address(market));
        MinimalMockToken(CANARY_TOKEN_ADDR).transfer(address(manager), PHYSICAL_TOKEN_SUPPLY);
        manager.settle();
        manager.mint(address(market), uint256(uint160(CANARY_TOKEN_ADDR)), PHYSICAL_TOKEN_SUPPLY);
        return bytes("");
    }

    /// @notice The decisive test: instance #1 adds the sentinel; instance #2 - a completely
    ///         separate contract instance, created fresh, sharing no state with instance #1
    ///         beyond the live chain itself - predicts the SAME helper address and removes the
    ///         exact position instance #1 created. Covers requirements 1-6.
    struct ProbeContext {
        SentinelLiquidityProbe probe1;
        address predictedHelper;
        address thirdPartyLpAddr;
        bytes32 thirdPartySalt;
        uint128 thirdPartyLiquidity;
        uint128 liquidityBeforeSentinel;
    }

    /// @dev Shared setup for both tests below: deploys probe1, a third-party out-of-range
    ///      position (different salt, different tick range so it never contributes to the
    ///      active-liquidity figure), then runs addSentinel() once. Bundled into a struct to
    ///      keep each calling test's own local variable count low enough for the v4 profile's
    ///      via-ir pipeline.
    function _setupWithSentinelAdded() internal returns (ProbeContext memory ctx) {
        assertGt(CREATE2_DEPLOYER.code.length, 0, "requirement 1: CREATE2 factory must exist");

        ctx.probe1 = new SentinelLiquidityProbe();
        ctx.probe1.setUp();
        ctx.predictedHelper = ctx.probe1.predictedHelperAddress();
        assertEq(ctx.predictedHelper.code.length, 0, "sanity: predicted address must have no code yet");

        ctx.thirdPartySalt = keccak256("SOME_OTHER_LP_POSITION");
        address thirdParty = makeAddr("thirdPartyLP");
        vm.deal(thirdParty, 10 ether);
        MinimalMockToken(CANARY_TOKEN_ADDR).mint(thirdParty, 10_000e18);
        ctx.thirdPartyLpAddr = _addThirdPartyLiquidity(thirdParty, ctx.thirdPartySalt, 500);
        ctx.thirdPartyLiquidity = _positionLiquidity(ctx.thirdPartyLpAddr, ctx.thirdPartySalt);
        assertEq(ctx.thirdPartyLiquidity, 500, "sanity: third party's own position must exist first");

        (,, ctx.liquidityBeforeSentinel) = _slot0AndLiquidity();
        ctx.probe1.addSentinel();

        assertGt(ctx.predictedHelper.code.length, 0, "requirement 2: predicted address must now hold real deployed code");
        (,, uint128 liquidityAfterAdd) = _slot0AndLiquidity();
        assertEq(liquidityAfterAdd, ctx.liquidityBeforeSentinel + 1000, "requirement 4: active liquidity must increase by exactly 1,000 from addSentinel()");
        assertEq(_positionLiquidity(ctx.thirdPartyLpAddr, ctx.thirdPartySalt), ctx.thirdPartyLiquidity, "requirement 6: third party's own position unaffected by the sentinel's own add");
    }

    /// @notice Requirements 1, 2, 4, and the add-side half of 6: factory exists, predicted
    ///         address matches the actually-deployed one, liquidity increases by exactly
    ///         1,000, and a third party's own unrelated position is untouched.
    function test_sentinelAdd_predictionMatchesDeployment_thirdPartyUnaffected() public {
        _setupWithSentinelAdded();
    }

    /// @notice Requirements 3, 5, and the remove-side half of 6: a separate later invocation
    ///         predicts the same helper address, locates and removes the exact position,
    ///         funds return only to DEPLOYER, the third party's own position stays untouched,
    ///         and the position cannot be removed twice.
    function test_separateInvocationRemoves_fundsOnlyToDeployer_cannotRemoveTwice() public {
        ProbeContext memory ctx = _setupWithSentinelAdded();

        SentinelLiquidityProbe probe2 = new SentinelLiquidityProbe();
        probe2.setUp();
        assertEq(probe2.predictedHelperAddress(), ctx.predictedHelper, "requirement 3: a separate invocation must predict the exact same helper address");

        uint256 deployerEthBefore = DEPLOYER.balance;
        uint256 deployerTokenBefore = MinimalMockToken(CANARY_TOKEN_ADDR).balanceOf(DEPLOYER);
        address randomOther = makeAddr("randomOther");

        // Requirement 5: instance #2 locates the helper solely via predictedHelperAddress().
        probe2.removeSentinel();

        (,, uint128 liquidityAfterRemove) = _slot0AndLiquidity();
        assertEq(liquidityAfterRemove, ctx.liquidityBeforeSentinel, "requirement 6: active liquidity returns exactly to its pre-sentinel level (the third party's own out-of-range position never counted toward it either way)");
        assertGt(DEPLOYER.balance, deployerEthBefore, "requirement 6: funds must return to DEPLOYER");
        assertGt(MinimalMockToken(CANARY_TOKEN_ADDR).balanceOf(DEPLOYER), deployerTokenBefore, "requirement 6: funds must return to DEPLOYER");
        assertEq(randomOther.balance, 0, "requirement 6: funds must return ONLY to DEPLOYER");
        assertEq(MinimalMockToken(CANARY_TOKEN_ADDR).balanceOf(randomOther), 0, "requirement 6: funds must return ONLY to DEPLOYER");
        assertEq(_positionLiquidity(ctx.thirdPartyLpAddr, ctx.thirdPartySalt), ctx.thirdPartyLiquidity, "requirement 6: third party's own position remains unaffected by the sentinel's own removal");

        // Requirement 6: cannot be removed twice - a second attempt on an already-empty
        // position must revert (PoolManager's own liquidity accounting underflows).
        vm.expectRevert();
        probe2.removeSentinel();
    }

    /// @notice Requirement 7 (add side): addLiquidity must reject any non-positive
    ///         liquidityDelta, called directly against the helper (bypassing the script, which
    ///         only ever passes the fixed +1,000 value itself).
    function test_addLiquidity_rejectsNonPositiveLiquidityDelta() public {
        SentinelLiquidityProbe probe = new SentinelLiquidityProbe();
        probe.setUp();
        address helperAddr = probe.predictedHelperAddress();

        vm.startPrank(DEPLOYER);
        MinimalMockToken(CANARY_TOKEN_ADDR).approve(helperAddr, type(uint256).max);
        vm.stopPrank();

        // Deploy the helper first via a real add, then attempt bad calls against it directly.
        probe.addSentinel();
        SentinelLiquidityHelperLike helper = SentinelLiquidityHelperLike(payable(helperAddr));

        vm.startPrank(DEPLOYER);
        vm.expectRevert(bytes("addLiquidity requires a positive liquidityDelta"));
        helper.addLiquidity{value: 1e12}(
            SentinelLiquidityHelperLike.AddParams({key: key, tickLower: -887220, tickUpper: 887220, liquidityDelta: 0, salt: keccak256("x"), payer: DEPLOYER})
        );

        vm.expectRevert(bytes("addLiquidity requires a positive liquidityDelta"));
        helper.addLiquidity{value: 1e12}(
            SentinelLiquidityHelperLike.AddParams({key: key, tickLower: -887220, tickUpper: 887220, liquidityDelta: -5, salt: keccak256("x"), payer: DEPLOYER})
        );
        vm.stopPrank();
    }

    /// @notice Requirement 7 (remove side): removeLiquidity must reject any non-negative
    ///         liquidityDelta.
    function test_removeLiquidity_rejectsNonNegativeLiquidityDelta() public {
        SentinelLiquidityProbe probe = new SentinelLiquidityProbe();
        probe.setUp();
        probe.addSentinel();
        address helperAddr = probe.predictedHelperAddress();
        SentinelLiquidityHelperLike helper = SentinelLiquidityHelperLike(payable(helperAddr));

        vm.startPrank(DEPLOYER);
        vm.expectRevert(bytes("removeLiquidity requires a negative liquidityDelta"));
        helper.removeLiquidity(
            SentinelLiquidityHelperLike.RemoveParams({key: key, tickLower: -887220, tickUpper: 887220, liquidityDelta: 0, salt: keccak256("CLOG_SENTINEL_LIQUIDITY_PROBE_V1"), recipient: DEPLOYER})
        );

        vm.expectRevert(bytes("removeLiquidity requires a negative liquidityDelta"));
        helper.removeLiquidity(
            SentinelLiquidityHelperLike.RemoveParams({key: key, tickLower: -887220, tickUpper: 887220, liquidityDelta: 5, salt: keccak256("CLOG_SENTINEL_LIQUIDITY_PROBE_V1"), recipient: DEPLOYER})
        );
        vm.stopPrank();
    }

    /// @notice Requirement 7 (transfer guard): if the ERC20's own transfer() call to
    ///         PoolManager returns false (not a revert - a silent failure, exactly the case
    ///         the unchecked-return-value bug would have missed), addLiquidity must revert
    ///         rather than silently proceeding as if the transfer succeeded. Uses a dedicated,
    ///         isolated pool/token/hook setup so this doesn't disturb the main flow above.
    function test_addLiquidity_revertsIfTokenTransferReturnsFalse() public {
        FailableToken failableToken = new FailableToken();
        PoolManager freshManager = new PoolManager(address(this));
        ClogV4Hook freshHookImpl = new ClogV4Hook(IPoolManager(address(freshManager)), address(this));
        address freshHookAddr = address(0x2088);
        vm.etch(freshHookAddr, address(freshHookImpl).code);
        ClogV4Hook freshHook = ClogV4Hook(freshHookAddr);

        RewardVault freshRewardVault = new RewardVault(address(this), address(freshManager), freshHookAddr);
        freshHook.setRewardVault(address(freshRewardVault));

        MockTickerNFT freshTickerNFT = new MockTickerNFT();
        freshTickerNFT.setOwner(1, makeAddr("freshTickerOwner"));
        ClogMarket freshMarket = new ClogMarket(freshHookAddr, address(failableToken), address(freshTickerNFT), 1, makeAddr("freshMultisig"), VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS, address(new NoopEligibility()));

        PoolKey memory freshKey = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(failableToken)), fee: 0, tickSpacing: 60, hooks: IHooks(freshHookAddr)});
        freshHook.registerMarket(freshKey, address(freshMarket));
        freshManager.initialize(freshKey, 79228162514264337593543950336);

        SentinelLiquidityHelperLike helper = SentinelLiquidityHelperLike(payable(address(new SentinelLiquidityHelper(IPoolManager(address(freshManager)), DEPLOYER))));

        failableToken.mint(DEPLOYER, 1e18);
        vm.startPrank(DEPLOYER);
        failableToken.approve(address(helper), type(uint256).max);
        failableToken.setTransferShouldFail(true);
        vm.deal(DEPLOYER, 1 ether);
        vm.expectRevert(bytes("token transfer to pool manager failed"));
        helper.addLiquidity{value: 1e12}(
            SentinelLiquidityHelperLike.AddParams({key: freshKey, tickLower: -887220, tickUpper: 887220, liquidityDelta: 1000, salt: keccak256("x"), payer: DEPLOYER})
        );
        vm.stopPrank();
    }

    function _addThirdPartyLiquidity(address thirdParty, bytes32 salt, int256 liquidityDelta) internal returns (address lpHelperAddr) {
        vm.startPrank(thirdParty);
        ThirdPartyLpHelper lpHelper = new ThirdPartyLpHelper(IPoolManager(POOL_MANAGER_ADDR), key, salt);
        MinimalMockToken(CANARY_TOKEN_ADDR).approve(address(lpHelper), type(uint256).max);
        lpHelper.addLiquidity{value: 1e12}(liquidityDelta, thirdParty);
        vm.stopPrank();
        return address(lpHelper);
    }

    function _positionLiquidity(address owner, bytes32 salt) internal view returns (uint128 liquidity) {
        (liquidity,,) = StateLibrary.getPositionInfo(IPoolManager(POOL_MANAGER_ADDR), key.toId(), owner, 60, 120, salt);
    }

    function _slot0AndLiquidity() internal view returns (uint160 price, int24 tick, uint128 liquidity) {
        IPoolManager manager = IPoolManager(POOL_MANAGER_ADDR);
        (price, tick,,) = manager.getSlot0(key.toId());
        liquidity = manager.getLiquidity(key.toId());
    }

    receive() external payable {}
}

/// @dev Minimal typed interface mirroring SentinelLiquidityHelper's own public shape, used only
///      so this test file can call it without re-importing the concrete contract type in every
///      helper (avoids ambiguity between the real helper and this file's own test doubles).
interface SentinelLiquidityHelperLike {
    struct AddParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
        address payer;
    }

    struct RemoveParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
        address recipient;
    }

    function addLiquidity(AddParams calldata params) external payable returns (int256, int256);
    function removeLiquidity(RemoveParams calldata params) external returns (int256, int256);
}

/// @dev A standalone ERC20 whose transfer() can be switched to return false without reverting -
///      the exact shape needed to prove the transfer-return-value guard actually catches a
///      silent failure, not merely a revert (which the pre-existing transferFrom check already
///      would have caught).
contract FailableToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public transferShouldFail;

    function setTransferShouldFail(bool value) external {
        transferShouldFail = value;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (transferShouldFail) {
            return false;
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev A separate, independent LP position on the SAME pool as the sentinel, owned by a third
///      party, used only to prove the sentinel's own add/remove never touches anyone else's
///      position or salt.
contract ThirdPartyLpHelper {
    IPoolManager immutable manager;
    PoolKey key;
    bytes32 immutable salt;
    int24 constant TICK_LOWER = 60; // deliberately OUT OF RANGE of the current tick (0), so this
    int24 constant TICK_UPPER = 120; // position never contributes to Pool.State's own active
        // liquidity figure - isolating "is this specific position's own stored liquidity
        // untouched" from "does the global active-liquidity number change", which are two
        // different, both-necessary checks.

    constructor(IPoolManager manager_, PoolKey memory key_, bytes32 salt_) {
        manager = manager_;
        key = key_;
        salt = salt_;
    }

    function addLiquidity(int256 liquidityDelta, address payer) external payable {
        manager.unlock(abi.encode(liquidityDelta, payer));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (int256 liquidityDelta, address payer) = abi.decode(data, (int256, address));
        (BalanceDelta delta,) = manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liquidityDelta, salt: salt}), bytes(""));
        int128 eth = -delta.amount0();
        int128 tok = -delta.amount1();
        if (eth > 0) {
            manager.sync(key.currency0);
            manager.settle{value: uint256(int256(eth))}();
        }
        if (tok > 0) {
            address tokenAddr = Currency.unwrap(key.currency1);
            IMintableToken(tokenAddr).transferFrom(payer, address(this), uint256(int256(tok)));
            manager.sync(key.currency1);
            IMintableToken(tokenAddr).transfer(address(manager), uint256(int256(tok)));
            manager.settle();
        }
        return bytes("");
    }

    receive() external payable {}
}

interface IMintableToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}
