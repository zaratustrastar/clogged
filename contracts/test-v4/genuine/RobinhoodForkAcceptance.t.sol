// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {ClogGenuineLiquidityHook} from "../../src-v4/genuine/ClogGenuineLiquidityHook.sol";
import {ClogGenuineRegistry} from "../../src-v4/genuine/ClogGenuineRegistry.sol";
import {ClogFourPositionMath} from "../../src-v4/genuine/ClogFourPositionMath.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {TickerNFT} from "../../src/TickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";

interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2Like {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @title RobinhoodForkAcceptance
/// @notice Full disposable launch + real routing stack against the DEPLOYED Robinhood contracts.
///         Nothing is broadcast; no deployer key is used.
contract RobinhoodForkAcceptanceTest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IUniversalRouter constant UR = IUniversalRouter(0x8876789976dEcBfCbBbe364623C63652db8C0904);
    IPermit2Like constant PERMIT2 = IPermit2Like(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IV4Quoter constant QUOTER = IV4Quoter(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    address constant SAFE = 0x29DEf4F5429CAC1e364263C449A7aE791657d48F;

    uint256 constant SEED = 9 ether;
    uint256 constant BUFFER = 20_000;
    uint256 constant VT = 800_000_000e18;

    // Universal Router: V4_SWAP command; v4 actions SWAP_EXACT_IN_SINGLE / SETTLE_ALL / TAKE_ALL
    bytes1 constant CMD_V4_SWAP = 0x10;
    uint8 constant ACT_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 constant ACT_SETTLE_ALL = 0x0c;
    uint8 constant ACT_TAKE_ALL = 0x0f;

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    ClogGenuineLiquidityHook hook;
    ClogFourPositionMath geometry;
    ClogGenuineRegistry registry;
    TickerNFT nft;
    RewardVault vault;
    MemeToken token;
    ClogMarket market;
    PoolKey key;
    PoolId pid;
    uint256 tokenId;

    address multisig = makeAddr("ms");
    address deployer = makeAddr("dep");
    address launcher = makeAddr("launcher");
    address owner;
    address trader = makeAddr("trader");

    uint8 constant BOUNDARY = 1;
    uint8 constant FOUR = 2;
    uint8 constant NEAR = 3;

    function setUp() public {
        vm.skip(bytes(vm.envOr("ROBINHOOD_RPC", string(""))).length == 0);
        owner = launcher;

        nft = new TickerNFT("RHF", "RHF", deployer, "https://x/", multisig);
        geometry = new ClogFourPositionMath(ClogFourPositionMath.HhMode.HI);
        registry = new ClogGenuineRegistry(
            SAFE, address(nft), multisig, address(new NoopEligibility()), SEED, BUFFER
        );

        bytes32 h = keccak256(
            abi.encodePacked(
                type(ClogGenuineLiquidityHook).creationCode,
                abi.encode(PM, address(registry), geometry)
            )
        );
        bytes32 salt;
        for (uint256 i = 0; i < 500_000; i++) {
            address c = vm.computeCreate2Address(bytes32(i), h, address(this));
            if (uint160(c) & uint160((1 << 14) - 1) == uint160(0x2ACC)) { salt = bytes32(i); break; }
        }
        hook = new ClogGenuineLiquidityHook{salt: salt}(PM, address(registry), geometry);
        vault = new RewardVault(makeAddr("rm"), address(PM), address(hook));
        registry.setV4Infrastructure(address(PM), address(hook), address(vault));

        vm.prank(deployer);
        nft.setRegistry(address(registry));
    }

    function _mode() internal view returns (uint8) {
        return uint8(hook.geometryMode(pid));
    }

    function _invariants() internal view {
        assertEq(market.re() - market.realETH(), SEED, "re - realETH");
        assertEq(market.rt() - market.physicalInventory(), VT, "rt - physInv");
    }

    function _conservation() internal view {
        assertEq(
            token.balanceOf(address(PM)) + token.balanceOf(address(hook)) + token.balanceOf(trader),
            1_000_000_000e18,
            "token conservation"
        );
    }

    // ── real Universal Router exact-input v4 route ──
    function _urBuy(uint256 amtIn) internal returns (uint256 got) {
        bytes memory actions =
            abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: uint128(amtIn),
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(key.currency0, amtIn);
        params[2] = abi.encode(key.currency1, uint256(0));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        uint256 before = token.balanceOf(trader);
        vm.deal(trader, trader.balance + amtIn);
        vm.prank(trader);
        UR.execute{value: amtIn}(abi.encodePacked(CMD_V4_SWAP), inputs, block.timestamp + 300);
        got = token.balanceOf(trader) - before;
    }

    function _urSell(uint256 amtIn) internal returns (uint256 got) {
        bytes memory actions =
            abi.encodePacked(ACT_SWAP_EXACT_IN_SINGLE, ACT_SETTLE_ALL, ACT_TAKE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: uint128(amtIn),
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(key.currency1, amtIn);
        params[2] = abi.encode(key.currency0, uint256(0));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        uint256 before = trader.balance;
        vm.startPrank(trader);
        token.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(token), address(UR), type(uint160).max, uint48(block.timestamp + 3600));
        UR.execute(abi.encodePacked(CMD_V4_SWAP), inputs, block.timestamp + 300);
        vm.stopPrank();
        got = trader.balance - before;
    }

    function test_forkAcceptance() public {
        // ── 1. launch through the Registry on the REAL PoolManager ──
        token = new MemeToken("RHF", "RHF", address(registry));
        uint256 safeBefore = SAFE.balance;
        uint256 vaultBefore = address(vault).balance;

        vm.deal(launcher, 1 ether);
        uint256 g = gasleft();
        vm.prank(launcher);
        address mkt;
        (tokenId, mkt) = registry.launch{value: 0.002 ether}(address(token), 1);
        emit log_named_uint("GAS launch (real PM)", g - gasleft());
        market = ClogMarket(mkt);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        pid = key.toId();

        assertEq(SAFE.balance - safeBefore, 0.002 ether, "Safe must receive exactly 0.002 ETH");
        assertEq(address(registry).balance, 0, "Registry retains 0");
        assertEq(address(vault).balance, vaultBefore, "WinnerPot gets 0 launch fee");
        assertEq(nft.ownerOf(tokenId), launcher, "TickerNFT to launcher");
        assertEq(_mode(), BOUNDARY, "initial mode SINGLE_BOUNDARY");
        assertEq(market.realETH(), 0, "no real ETH at launch");
        assertGt(token.balanceOf(address(PM)), 0, "position holds token");
        _invariants();

        // ── 2. V4Quoter before a representative buy ──
        (uint256 qOut, uint256 qGas) = QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: true, exactAmount: uint128(0.01 ether), hookData: ""
            })
        );
        emit log_named_uint("V4Quoter buy amountOut", qOut);
        emit log_named_uint("V4Quoter buy gasEstimate", qGas);
        assertGt(qOut, 0, "quoter must return a usable buy quote");

        // ── 3. small buy through Universal Router -> NEAR_BOUNDARY ──
        uint256 got = _urBuy(0.0001 ether);
        emit log_named_uint("UR small buy out", got);
        assertGt(got, 0, "UR small buy delivered nothing");
        assertEq(_mode(), NEAR, "small buy -> NEAR_BOUNDARY");
        _invariants(); _conservation();

        // ── 4. larger buy -> THREE_EXACT ──
        got = _urBuy(1 ether);
        emit log_named_uint("UR larger buy out", got);
        assertEq(_mode(), FOUR, "larger buy -> THREE_EXACT");
        _invariants(); _conservation();

        // ── 5. ordinary buy ──
        _urBuy(0.3 ether);
        assertEq(_mode(), FOUR, "ordinary buy stays THREE_EXACT");
        _invariants(); _conservation();

        // ── 6. quoter for a sell, then ordinary sell via Permit2 ──
        (uint256 qSell,) = QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: false, exactAmount: uint128(1_000_000e18), hookData: ""
            })
        );
        emit log_named_uint("V4Quoter sell amountOut", qSell);

        uint256 eth = _urSell(token.balanceOf(trader) / 4);
        emit log_named_uint("UR sell ETH out", eth);
        assertGt(eth, 0, "sell paid nothing");
        _invariants(); _conservation();

        // ── 7. capped sell -> SINGLE_BOUNDARY ──
        uint256 hookEthBefore = address(hook).balance;
        _urSell(token.balanceOf(trader));
        assertEq(market.realETH(), 0, "capped sell must exhaust realETH");
        assertEq(_mode(), BOUNDARY, "capped sell -> SINGLE_BOUNDARY");
        assertEq(address(hook).balance, hookEthBefore, "no protocol ETH injected");
        _invariants(); _conservation();

        // ── 8. buy after capped sell ──
        _urBuy(0.5 ether);
        assertTrue(_mode() == FOUR || _mode() == NEAR, "buy after capped restores a trading mode");
        _invariants(); _conservation();

        // ── 9. withdrawals ──
        uint256 ownerOwed = market.pendingWithdrawals(owner);
        uint256 msOwed = market.pendingWithdrawals(multisig);
        assertGt(ownerOwed, 0, "owner accrued nothing");
        assertGt(msOwed, 0, "multisig accrued nothing");
        uint256 ob = owner.balance;
        market.withdraw(owner);
        assertEq(owner.balance - ob, ownerOwed, "owner withdrawal exact");
        uint256 mb = multisig.balance;
        market.withdraw(multisig);
        assertEq(multisig.balance - mb, msOwed, "multisig withdrawal exact");

        emit log_named_uint("WinnerPot ERC6909 claims", PM.balanceOf(address(vault), 0));
        emit log_named_uint("max ETH settlement cost", hook.maxSettlementCost(pid));
        assertLe(hook.maxSettlementCost(pid), 100, "settlement cost above 100 wei");
    }
}
