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
import {MockTickerNFT} from "../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../src/RewardVault.sol";

/// @notice Official IV4Router.ExactInputSingleParams shape (the 5-field version published in
///         Uniswap's own "Swap Routing on Uniswap v4" developer guide and used throughout its
///         SDK-based examples - confirmed via web search against docs.uniswap.org before writing
///         this, not assumed). A newer 6-field variant (adding minHopPriceX36 per-hop slippage)
///         also exists on v4-periphery's main branch; which shape Robinhood's own deployed
///         Universal Router/V4Router actually expects is exactly the kind of detail that must be
///         confirmed against their real deployed ABI on the fork, not guessed here - this file
///         deliberately uses the simpler, more widely-documented shape, since CLOG's own hook
///         does not depend on minHopPriceX36 either way, and the property under test here (does
///         the hook behave correctly under ordinary, standard action ordering) is identical
///         under both shapes.
struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes hookData;
}

/// @title Standard V4Router-shaped action execution against the real ClogV4Hook
/// @notice NOT the real Uniswap Universal Router or V4Router - those live in separate
///         repositories (v4-periphery, universal-router) this branch deliberately does not
///         install, per explicit instruction not to block on pulling in whole repos
///         unnecessarily when the decisive acceptance test is a Robinhood mainnet/testnet fork
///         against their own actual deployed stack (PoolManager, Universal Router, V4Quoter,
///         Permit2) - something only that fork environment can provide.
///
///         What this DOES prove, locally, against the real (test-mined or vm.etch'd) ClogV4Hook
///         and a real PoolManager: that the hook responds correctly to the EXACT action
///         sequence and struct encoding a real V4Router uses internally
///         (SWAP_EXACT_IN_SINGLE -> SETTLE_ALL -> TAKE_ALL, verified action byte values 0x06,
///         0x0c, 0x0f against Uniswap's own published Actions enumeration and V4Router source
///         before writing this), using the OFFICIAL struct shape and OFFICIAL constant values
///         - not a CLOG-specific shortcut, not a different action ordering, nothing the hook
///         needs to special-case. StandardV4RouterMirror below is a small, deliberately
///         faithful re-implementation of V4Router._handleAction's own dispatch logic for
///         exactly these three actions (traced directly against the real V4Router.sol source
///         quoted in this file's own commit message) - it is not a mock that always succeeds;
///         it performs the real poolManager.swap/settle/take calls a real router would.
contract StandardV4RouterMirror is IUnlockCallback {
    // Verified directly against Uniswap's own published Actions.sol / v4-sdk Actions
    // enumeration before writing this (see this file's own top-level docs).
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice Mirrors V4Router's own public entrypoint shape: caller supplies the encoded
    ///         (actions, params) pair exactly as V4Planner.finalize() would produce it, this
    ///         contract calls poolManager.unlock() and dispatches each action in order inside
    ///         the callback - the real V4Router's own _executeActions/_handleAction pattern,
    ///         traced directly against source.
    function execute(bytes calldata actions, bytes[] calldata params) external payable returns (bytes memory) {
        return poolManager.unlock(abi.encode(msg.sender, actions, params));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (address payer, bytes memory actions, bytes[] memory params) = abi.decode(data, (address, bytes, bytes[]));

        BalanceDelta lastSwapDelta;
        PoolKey memory lastPoolKey;
        for (uint256 i = 0; i < actions.length; i++) {
            uint8 action = uint8(actions[i]);
            if (action == SWAP_EXACT_IN_SINGLE) {
                ExactInputSingleParams memory p = abi.decode(params[i], (ExactInputSingleParams));
                lastPoolKey = p.poolKey;
                lastSwapDelta = poolManager.swap(
                    p.poolKey,
                    IPoolManager.SwapParams({
                        zeroForOne: p.zeroForOne,
                        amountSpecified: -int256(uint256(p.amountIn)),
                        sqrtPriceLimitX96: p.zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
                    }),
                    p.hookData
                );
            } else if (action == SETTLE_ALL) {
                (Currency currency, uint256 maxAmount) = abi.decode(params[i], (Currency, uint256));
                int128 deltaForCurrency = currency == lastPoolKey.currency0 ? lastSwapDelta.amount0() : lastSwapDelta.amount1();
                require(deltaForCurrency < 0, "DeltaNotNegative");
                uint256 amount = uint256(int256(-deltaForCurrency));
                require(amount <= maxAmount, "V4TooMuchRequested");
                poolManager.sync(currency);
                if (currency.isAddressZero()) {
                    poolManager.settle{value: amount}();
                } else {
                    _ERC20Like(Currency.unwrap(currency)).transferFrom(payer, address(poolManager), amount);
                    poolManager.settle();
                }
            } else if (action == TAKE_ALL) {
                (Currency currency, uint256 minAmount) = abi.decode(params[i], (Currency, uint256));
                int128 deltaForCurrency = currency == lastPoolKey.currency0 ? lastSwapDelta.amount0() : lastSwapDelta.amount1();
                require(deltaForCurrency > 0, "DeltaNotPositive");
                uint256 amount = uint256(int256(deltaForCurrency));
                require(amount >= minAmount, "V4TooLittleReceived");
                poolManager.take(currency, payer, amount);
            } else {
                revert("unsupported action in this mirror");
            }
        }

        return abi.encode(lastSwapDelta);
    }

    receive() external payable {}
}

interface _ERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title Standard V4Quoter-shaped simulate-and-revert quoting against the real ClogV4Hook
/// @notice Mirrors V4Quoter's own published pattern (confirmed against docs.uniswap.org's own
///         IV4Quoter reference before writing this): quoteExactInputSingle takes a poolKey/
///         zeroForOne/exactAmount/hookData tuple, actually executes the swap against a real
///         PoolManager inside its own unlock(), and reports the result - the real V4Quoter does
///         this via a deliberate revert-and-decode pattern (never actually committing state);
///         this mirror achieves the same "no state committed" property more directly, using
///         `vm`'s own snapshot/revert cheatcodes from the calling test rather than reproducing
///         V4Quoter's internal revert-encoding trick byte-for-byte - the OBSERVABLE property
///         under test (a quote for a given size must equal what an actual trade of that same
///         size later produces) is identical either way, and is what a real Robinhood-fork test
///         must also confirm against their actual deployed V4Quoter.
contract StandardV4QuoterMirror is IUnlockCallback {
    IPoolManager public immutable poolManager;

    /// @dev The real V4Quoter encodes its quote result as a custom error and lets the entire
    ///      unlock() revert with it - callers decode the result FROM the revert reason, and
    ///      because the whole call reverted, absolutely nothing the swap did is ever committed
    ///      (not merely "discarded by a test cheatcode" - genuinely, structurally never
    ///      committed on any chain, exactly like the real thing).
    error QuoteResult(uint256 amountOut);

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    /// @notice Returns the exact-input quote by actually running the swap inside unlock(), then
    ///         deliberately reverting the ENTIRE call with the result encoded in a custom error
    ///         - genuinely never committing any state, on-chain, structurally, exactly matching
    ///         real V4Quoter's own contract (confirmed against docs.uniswap.org's IV4Quoter
    ///         reference before writing this).
    function quoteExactInputSingle(QuoteExactSingleParams calldata params) external returns (uint256 amountOut) {
        try poolManager.unlock(abi.encode(params)) returns (bytes memory) {
            revert("StandardV4QuoterMirror: unlock unexpectedly succeeded");
        } catch (bytes memory reason) {
            require(reason.length == 36, "StandardV4QuoterMirror: unexpected revert shape");
            bytes memory inner = new bytes(32);
            for (uint256 i = 0; i < 32; i++) {
                inner[i] = reason[i + 4];
            }
            amountOut = abi.decode(inner, (uint256));
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        QuoteExactSingleParams memory p = abi.decode(data, (QuoteExactSingleParams));
        BalanceDelta delta = poolManager.swap(
            p.poolKey,
            IPoolManager.SwapParams({
                zeroForOne: p.zeroForOne,
                amountSpecified: -int256(uint256(p.exactAmount)),
                sqrtPriceLimitX96: p.zeroForOne ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            p.hookData
        );
        int128 unspecified = p.zeroForOne ? delta.amount1() : delta.amount0();
        revert QuoteResult(uint256(int256(unspecified)));
    }
}

/// @title Ordinary router integration: standard action ordering, no CLOG-specific behavior
contract StandardRouterIntegrationTest is Test, IUnlockCallback {
    PoolManager manager;
    ClogV4Hook hook;
    ClogMarket market;
    MinimalMockToken token;
    MockTickerNFT tickerNFT;
    RewardVault rewardVault;
    PoolKey key;
    StandardV4RouterMirror router;
    StandardV4QuoterMirror quoter;

    address tickerOwner = makeAddr("tickerOwner");
    address multisig = makeAddr("multisig");
    address trader = makeAddr("trader");
    uint256 constant TICKER_TOKEN_ID = 1;
    address constant HOOK_ADDRESS = address(0x2088);
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000;
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;

    bool private _depositing;

    function setUp() public {
        manager = new PoolManager(address(this));
        ClogV4Hook impl = new ClogV4Hook(IPoolManager(address(manager)), address(this));
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = ClogV4Hook(HOOK_ADDRESS);

        rewardVault = new RewardVault(address(this), address(manager), HOOK_ADDRESS);
        hook.setRewardVault(address(rewardVault));

        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(TICKER_TOKEN_ID, tickerOwner);

        token = new MinimalMockToken();
        market = new ClogMarket(HOOK_ADDRESS, address(token), address(tickerNFT), TICKER_TOKEN_ID, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS);

        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(HOOK_ADDRESS)});
        hook.registerMarket(key, address(market));
        manager.initialize(key, 79228162514264337593543950336);

        token.mint(address(market), PHYSICAL_TOKEN_SUPPLY);
        _depositing = true;
        manager.unlock(bytes(""));
        _depositing = false;

        vm.startPrank(address(market));
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(token))), type(uint256).max);
        manager.approve(HOOK_ADDRESS, uint256(uint160(address(0))), type(uint256).max);
        vm.stopPrank();

        router = new StandardV4RouterMirror(IPoolManager(address(manager)));
        quoter = new StandardV4QuoterMirror(IPoolManager(address(manager)));

        vm.deal(trader, 10 ether);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Used only by this test's own setUp() deposit step - the router/quoter mirrors above
        // implement their own unlockCallback for everything else in this file.
        require(msg.sender == address(manager), "not pool manager");
        require(_depositing, "unexpected unlock");
        manager.sync(key.currency1);
        vm.prank(address(market));
        token.transfer(address(manager), PHYSICAL_TOKEN_SUPPLY);
        manager.settle();
        manager.mint(address(market), uint256(uint160(address(token))), PHYSICAL_TOKEN_SUPPLY);
        return bytes("");
    }

    receive() external payable {}

    // ── V4Quoter -> quote buy, Universal Router -> buy, matching exactly ────────────────────

    function test_quoteBuy_thenRealBuy_matchesExactly() public {
        uint256 buyAmount = 0.05 ether;

        // Quote via the standard revert-based simulate pattern - genuinely, structurally never
        // commits any state (the whole unlock() call reverts), exactly like real V4Quoter.
        StandardV4QuoterMirror.QuoteExactSingleParams memory quoteParams = StandardV4QuoterMirror.QuoteExactSingleParams({
            poolKey: key,
            zeroForOne: true,
            exactAmount: uint128(buyAmount),
            hookData: bytes("")
        });
        uint256 quotedOut = quoter.quoteExactInputSingle(quoteParams);

        // Now the REAL trade, through the standard V4Router-shaped action sequence - ordinary
        // action ordering (SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL), no CLOG-specific router
        // behavior anywhere in this call.
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInputSingleParams({poolKey: key, zeroForOne: true, amountIn: uint128(buyAmount), amountOutMinimum: 0, hookData: bytes("")}));
        params[1] = abi.encode(key.currency0, buyAmount);
        params[2] = abi.encode(key.currency1, uint256(0));

        vm.prank(trader);
        router.execute{value: buyAmount}(actions, params);
        uint256 actualOut = token.balanceOf(trader);

        assertGt(actualOut, 0, "the real trade through the standard router action sequence must deliver real tokens");
        assertEq(actualOut, quotedOut, "the quote must match the real trade exactly - standard V4Quoter/V4Router action ordering, no CLOG-specific behavior needed for either");
    }

    // ── V4Quoter -> quote sell, Universal Router -> sell, matching exactly ──────────────────

    function test_quoteSell_thenRealSell_matchesExactly() public {
        // Acquire real tokens first via the standard router, exactly as a real user would.
        uint256 buyAmount = 0.05 ether;
        bytes memory buyActions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory buyParams = new bytes[](3);
        buyParams[0] = abi.encode(ExactInputSingleParams({poolKey: key, zeroForOne: true, amountIn: uint128(buyAmount), amountOutMinimum: 0, hookData: bytes("")}));
        buyParams[1] = abi.encode(key.currency0, buyAmount);
        buyParams[2] = abi.encode(key.currency1, uint256(0));
        vm.prank(trader);
        router.execute{value: buyAmount}(buyActions, buyParams);
        uint256 tokensHeld = token.balanceOf(trader);
        uint256 sellAmount = tokensHeld / 2;

        vm.prank(trader);
        token.approve(address(router), type(uint256).max);

        StandardV4QuoterMirror.QuoteExactSingleParams memory quoteParams = StandardV4QuoterMirror.QuoteExactSingleParams({
            poolKey: key,
            zeroForOne: false,
            exactAmount: uint128(sellAmount),
            hookData: bytes("")
        });
        uint256 quotedOut = quoter.quoteExactInputSingle(quoteParams);

        bytes memory sellActions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory sellParams = new bytes[](3);
        sellParams[0] = abi.encode(ExactInputSingleParams({poolKey: key, zeroForOne: false, amountIn: uint128(sellAmount), amountOutMinimum: 0, hookData: bytes("")}));
        sellParams[1] = abi.encode(key.currency1, sellAmount);
        sellParams[2] = abi.encode(key.currency0, uint256(0));

        uint256 traderEthBefore = trader.balance;
        vm.prank(trader);
        router.execute(sellActions, sellParams);
        uint256 actualOut = trader.balance - traderEthBefore;

        assertGt(actualOut, 0, "the real sell through the standard router action sequence must deliver real ETH");
        assertEq(actualOut, quotedOut, "the sell quote must match the real sell exactly");
    }
}
