// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {RouterParameters} from "@uniswap/universal-router/types/RouterParameters.sol";
import {Commands} from "@uniswap/universal-router/libraries/Commands.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {EligibilityRegistry} from "../../src/EligibilityRegistry.sol";
import {TickerNFT} from "../../src/TickerNFT.sol";
import {TickerRegistry} from "../../src/TickerRegistry.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {BondingCurveClog} from "../../src/BondingCurveClog.sol";
import {ClogV4Hook} from "../../src/ClogV4Hook.sol";

/// @notice Integration test against the REAL, OFFICIAL Uniswap universal-router package
/// (tag 2.2.0, commit 020e1b786ad9a6bad924874752167934734ad1e1) - not the hand-built TestRouter
/// used in ClogV4Hook.t.sol. Proves the full production path:
///   user -> UniversalRouter -> V4_SWAP -> SETTLE -> SWAP_EXACT_IN_SINGLE -> TAKE_ALL -> ClogV4Hook
///   -> BondingCurveClog
/// UniversalRouter itself is used completely unmodified - only Commands.V4_SWAP's own,
/// already-existing action-encoding surface is used, exactly as any real integrator would.
///
/// IMPORTANT HONESTY NOTE ON REPRESENTATIVENESS: third-party documentation (Bags, an unrelated
/// token-launch protocol also live on Robinhood Chain) states that the UniversalRouter actually
/// deployed at 0x8876789976dEcBfCbBbe364623C63652db8C0904 on Robinhood Chain is described as a
/// "Robinhood-modified fork" with an extra minHopPriceX36 field on its v4 swap struct. This
/// sandbox has no network access to Robinhood's RPC (confirmed directly: the domain is not in
/// the egress allowlist) or to the deployed bytecode, so the exact deployed contract could not be
/// fetched or diffed against the official source. The official IV4Router.ExactInputSingleParams
/// struct THIS TEST uses already includes minHopPriceX36 natively (verified directly in the
/// vendored v4-periphery source, not assumed) - so if the "fork" is simply a newer commit pin
/// that already carries this field upstream (plausible, since Bags' own warning is dated relative
/// to when stock UR/SDKs lagged behind), this test may already be representative. But this could
/// not be independently confirmed against the live bytecode, and this test result should not be
/// read as proof of byte-for-byte identity with whatever exact contract is live at that address.
/// @dev Minimal interface for the real UniversalRouter's execute() entry points - deliberately
/// NOT importing UniversalRouter.sol's full source into this compilation unit. UniversalRouter
/// inherits Dispatcher, which unconditionally also inherits its v2 and v3 swap modules (used for
/// completely unrelated command types this test never touches) - those modules transitively
/// import the real, official Uniswap v3-periphery npm package, which itself pins an
/// OpenZeppelin 3.4.1-solc-0.7-2 build (a genuinely Solidity-0.7-only package: verified
/// directly, not assumed). That is incompatible, in the same compilation unit, with this
/// project's own 0.8.24+ files. universal-router's own repository builds this exact same source
/// successfully as an ISOLATED project (confirmed directly: `cd lib/universal-router && forge
/// build` succeeds using universal-router's own, unmodified remappings.txt) - the conflict is
/// specific to importing it directly alongside this project's own global OpenZeppelin
/// remapping, not a defect in UniversalRouter itself. The real, unmodified, officially-compiled
/// UniversalRouter bytecode is deployed below via vm.deployCode against that separately-built
/// artifact - this interface only describes the entry points this test actually calls.
interface IUniversalRouterMinimal {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

contract ClogUniversalRouterTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    PoolManager manager;
    EligibilityRegistry engine;
    TickerNFT tickerNFT;
    TickerRegistry registry;
    ClogV4Hook hook;
    IUniversalRouterMinimal router;
    IAllowanceTransfer permit2;

    address multisig = makeAddr("multisig");
    address winnerPot = makeAddr("winnerPot");
    address governance = makeAddr("governance");
    address user = makeAddr("user");
    address userDirect = makeAddr("userDirect");

    uint256 constant BUFFER_BPS = 20_000;
    uint256 constant VIRTUAL_TOKEN_SEED = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 constant VIRTUAL_ETH_SEED = (5e9 * VIRTUAL_TOKEN_SEED) / 1e18;

    function _deployFromArtifact(string memory relativePath, bytes memory constructorArgs)
        internal
        returns (address deployed)
    {
        string memory artifactJson = vm.readFile(string.concat(vm.projectRoot(), relativePath));
        bytes memory creationCode = vm.parseJsonBytes(artifactJson, ".bytecode.object");
        deployed = _deployFromCreationCode(creationCode, constructorArgs);
    }

    function _deployFromCreationCode(bytes memory creationCode, bytes memory constructorArgs)
        internal
        returns (address deployed)
    {
        bytes memory deployData = abi.encodePacked(creationCode, constructorArgs);
        assembly {
            deployed := create(0, add(deployData, 0x20), mload(deployData))
        }
        require(deployed != address(0), "artifact deployment failed");
    }

    function setUp() public {
        manager = new PoolManager(address(this));
        engine = new EligibilityRegistry(address(this), 500, 0.229 ether, 1_800);
        engine.setRoundManager(makeAddr("roundManager"));
        tickerNFT =
            new TickerNFT("PMFI Casino Tickers", "TICKER", address(this), "https://clog.run/api/ticker-metadata/");
        registry = new TickerRegistry(
            address(engine), address(tickerNFT), multisig, winnerPot, governance, VIRTUAL_ETH_SEED, BUFFER_BPS
        );
        tickerNFT.setRegistry(address(registry));

        // Permit2's own pragma (exactly 0.8.17) is incompatible with this test file's pragma
        // (^0.8.24) for direct import, and nothing else in this project's build graph compiles
        // Permit2.sol concretely (only the IAllowanceTransfer interface is imported anywhere) -
        // so, like UniversalRouter above, it's built as its own isolated compilation (permit2's
        // own repo, skipping its own test/script files which hit an unrelated forge-std version
        // mismatch) and deployed here via the same raw bytecode read, bypassing Foundry's
        // artifact index entirely.
        permit2 = IAllowanceTransfer(_deployFromArtifact("/out/Permit2External.sol/Permit2.json", bytes("")));

        ClogV4Hook impl = new ClogV4Hook(manager, registry);
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        address hookAddress = address(flags ^ (0x7777 << 144));
        vm.etch(hookAddress, address(impl).code);
        hook = ClogV4Hook(payable(hookAddress));

        // The real, official UniversalRouter, deployed completely unmodified - only the fields
        // this test's V4_SWAP path actually exercises are set to real values; every other
        // integration surface (v2/v3/Across) is zeroed out since it's genuinely unused here, not
        // because those fields don't matter for a real deployment.
        RouterParameters memory params = RouterParameters({
            permit2: address(permit2),
            weth9: address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE), // never touched by a pure V4_SWAP native-ETH path
            v2Factory: address(0),
            v3Factory: address(0),
            pairInitCodeHash: bytes32(0),
            poolInitCodeHash: bytes32(0),
            v4PoolManager: address(manager),
            permissionsAdapterFactory: address(0),
            v3NFTPositionManager: address(0),
            v4PositionManager: address(0),
            spokePool: address(0)
        });
        // Requires the real UniversalRouter artifact to be built first - run
        // script/build-helpers/build-universal-router-artifact.sh once (or after updating
        // lib/universal-router) before running this test. See that script's own header comment
        // for why this can't just be a normal import into this project's build.
        //
        // Deploys via raw bytecode read + assembly create rather than vm.deployCode/vm.getCode:
        // both of those cheatcodes resolve paths against Foundry's own internal artifact index,
        // built from files it compiled THIS run - a manually-placed, externally-built artifact
        // (never part of this project's own source graph) is invisible to that index regardless
        // of how many times the project is rebuilt (confirmed directly: reproduces a known,
        // reported Foundry behavior - see foundry-rs/foundry#7607 for the identical symptom with
        // a cross-profile artifact). Reading the JSON file directly via vm.readFile/vm.parseJson
        // bypasses that index entirely - fs_permissions already grants read access to "./", which
        // covers this project's own out/ directory.
        router = IUniversalRouterMinimal(
            _deployFromArtifact("/out/UniversalRouterExternal.sol/UniversalRouter.json", abi.encode(params))
        );

        vm.deal(user, 1000 ether);
        vm.deal(userDirect, 1000 ether);
    }

    function _launchRealTicker(string memory ticker, address launcher)
        internal
        returns (uint256 tokenId, MemeToken token, BondingCurveClog market)
    {
        bytes32 salt = keccak256(abi.encode(ticker, block.timestamp, launcher));
        bytes32 tickerKey = keccak256(bytes(ticker));
        bytes32 commitHash = keccak256(abi.encode(launcher, tickerKey, salt));

        vm.prank(launcher);
        registry.commit(commitHash);
        vm.warp(block.timestamp + registry.MIN_REVEAL_DELAY());

        uint256 launchPrice = registry.LAUNCH_PRICE();
        vm.deal(launcher, launcher.balance + launchPrice);
        vm.prank(launcher);
        tokenId = registry.reveal{value: launchPrice}(ticker, salt);

        token = MemeToken(registry.tokenOf(tokenId));
        market = BondingCurveClog(registry.marketOf(tokenId));
    }

    function _poolKeyFor(MemeToken token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _v4SwapInputsBuy(PoolKey memory key, uint256 ethIn) internal pure returns (bytes memory) {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.TAKE_ALL));
        bytes[] memory swapParams = new bytes[](3);
        swapParams[0] = abi.encode(Currency.wrap(address(0)), ethIn, true);
        swapParams[1] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: uint128(ethIn),
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        swapParams[2] = abi.encode(key.currency1, uint256(0));
        return abi.encode(actions, swapParams);
    }

    function _v4SwapInputsSell(PoolKey memory key, uint256 tokenIn) internal pure returns (bytes memory) {
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.TAKE_ALL));
        bytes[] memory swapParams = new bytes[](3);
        swapParams[0] = abi.encode(key.currency1, tokenIn, true);
        swapParams[1] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                amountIn: uint128(tokenIn),
                amountOutMinimum: 0,
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        swapParams[2] = abi.encode(Currency.wrap(address(0)), uint256(0));
        return abi.encode(actions, swapParams);
    }

    /// 1. user -> UniversalRouter -> V4_SWAP -> SETTLE -> SWAP_EXACT_IN_SINGLE -> TAKE_ALL ->
    /// ClogV4Hook -> BondingCurveClog, native ETH -> meme token, through the REAL, unmodified
    /// official UniversalRouter.
    function test_universalRouter_buy_exactInput_ethToToken_matchesDirect() public {
        (uint256 tokenIdV4, MemeToken tokenV4, BondingCurveClog marketV4) = _launchRealTicker("URBUY", user);
        (, MemeToken tokenDirect, BondingCurveClog marketDirect) = _launchRealTicker("URBUYD", userDirect);
        hook.registerMarket(tokenIdV4);
        PoolKey memory key = _poolKeyFor(tokenV4);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        uint256 ethIn = 0.01 ether;
        vm.prank(userDirect);
        uint256 directOut = marketDirect.buy{value: ethIn}(0, block.timestamp);

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _v4SwapInputsBuy(key, ethIn);

        vm.prank(user);
        router.execute{value: ethIn}(commands, inputs);
        uint256 urOut = tokenV4.balanceOf(user);

        assertEq(urOut, directOut, "UniversalRouter buy output must exactly match direct buy() output");
        assertEq(marketV4.realReserve(), marketDirect.realReserve(), "realReserve must match");
        assertEq(marketV4.progressBps(), marketDirect.progressBps(), "progressBps must match");

        (uint128 liquidity) = IPoolManager(address(manager)).getLiquidity(key.toId());
        assertEq(liquidity, 0, "pool must have zero concentrated liquidity");
        assertEq(address(hook).balance, 0, "hook must hold zero ETH after the trade");
        assertEq(tokenV4.balanceOf(address(hook)), 0, "hook must hold zero token after the trade");

        IPoolManager mgr = IPoolManager(address(manager));
        assertEq(
            mgr.currencyDelta(address(router), Currency.wrap(address(0))), 0, "router ETH delta must clear to zero"
        );
        assertEq(
            mgr.currencyDelta(address(router), Currency.wrap(address(tokenV4))),
            0,
            "router token delta must clear to zero"
        );
        assertEq(mgr.currencyDelta(address(hook), Currency.wrap(address(0))), 0, "hook ETH delta must clear to zero");
        assertEq(
            mgr.currencyDelta(address(hook), Currency.wrap(address(tokenV4))), 0, "hook token delta must clear to zero"
        );

        console2.log("UniversalRouter BUY: direct tokensOut =", directOut);
        console2.log("UniversalRouter BUY: UR-path tokensOut =", urOut);
    }

    /// 2. meme -> native ETH, through the REAL, unmodified official UniversalRouter, with the
    /// ACTUAL expected Permit2 approval architecture: the user approves the MemeToken to Permit2
    /// (standard ERC20 approve, the one-time, per-token, reusable-across-any-Permit2-integrated-
    /// protocol step), then grants UniversalRouter a Permit2-level allowance for that token
    /// (Permit2.approve(token, spender, amount, expiration)) - never a direct ERC20 approval from
    /// the user to UniversalRouter itself, and never to BondingCurveClog or the hook directly.
    function test_universalRouter_sell_exactInput_tokenToEth_matchesDirect_withRealPermit2() public {
        (uint256 tokenIdV4, MemeToken tokenV4, BondingCurveClog marketV4) = _launchRealTicker("URSELL", user);
        (, MemeToken tokenDirect, BondingCurveClog marketDirect) = _launchRealTicker("URSELLD", userDirect);
        hook.registerMarket(tokenIdV4);
        PoolKey memory key = _poolKeyFor(tokenV4);
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        uint256 ethIn = 0.01 ether;
        vm.prank(userDirect);
        marketDirect.buy{value: ethIn}(0, block.timestamp);
        uint256 directBalance = tokenDirect.balanceOf(userDirect);

        bytes memory buyCommands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory buyInputs = new bytes[](1);
        buyInputs[0] = _v4SwapInputsBuy(key, ethIn);
        vm.prank(user);
        router.execute{value: ethIn}(buyCommands, buyInputs);
        uint256 urBalance = tokenV4.balanceOf(user);
        assertEq(urBalance, directBalance, "pre-sell balances must match");

        vm.startPrank(userDirect);
        tokenDirect.approve(address(marketDirect), directBalance);
        (uint256 directEthOut,) = marketDirect.sell(directBalance, 0, block.timestamp);
        vm.stopPrank();

        // The actual expected Permit2 approval architecture, exactly as a real frontend would do:
        vm.startPrank(user);
        tokenV4.approve(address(permit2), type(uint256).max); // step 1: ERC20 approve to Permit2 itself
        permit2.approve(address(tokenV4), address(router), uint160(urBalance), uint48(block.timestamp + 3600)); // step 2: Permit2-level allowance to UniversalRouter
        vm.stopPrank();

        bytes memory sellCommands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory sellInputs = new bytes[](1);
        sellInputs[0] = _v4SwapInputsSell(key, urBalance);

        uint256 ethBefore = user.balance;
        vm.prank(user);
        router.execute(sellCommands, sellInputs);
        uint256 urEthOut = user.balance - ethBefore;

        assertEq(urEthOut, directEthOut, "UniversalRouter sell output must exactly match direct sell() output");
        assertEq(marketV4.realReserve(), marketDirect.realReserve(), "realReserve must match after sell");

        // Confirm the actual transfer went through Permit2, not a leftover direct allowance to
        // the router or hook - the user never approved either of those directly for the token.
        assertEq(tokenV4.allowance(user, address(router)), 0, "user must never have approved the router directly");
        assertEq(tokenV4.allowance(user, address(hook)), 0, "user must never have approved the hook directly");
        assertEq(
            tokenV4.allowance(address(hook), address(marketV4)),
            0,
            "hook's allowance to the market must be zero after the trade"
        );

        assertEq(address(hook).balance, 0, "hook must hold zero ETH after sell");
        assertEq(tokenV4.balanceOf(address(hook)), 0, "hook must hold zero token after sell");

        console2.log("UniversalRouter SELL: direct ethOut  =", directEthOut);
        console2.log("UniversalRouter SELL: UR-path ethOut =", urEthOut);
    }
}
