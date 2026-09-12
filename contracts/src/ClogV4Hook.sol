// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {BondingCurveClog} from "./BondingCurveClog.sol";
import {MemeToken} from "./MemeToken.sol";
import {TickerRegistry} from "./TickerRegistry.sol";

/// @title ClogV4Hook
/// @notice A single, universal Uniswap v4 hook covering every CLOG meme market. It is a
///         COMPATIBILITY/EXECUTION SHELL, not a second market: it holds no independent economic
///         liquidity, requires no prefunded working capital, and routes every trade into the
///         canonical, unmodified BondingCurveClog for that ticker. See the settlement-flow notes
///         on `beforeSwap` for exactly how a zero-liquidity pool is made to work.
///
/// @dev MARKET VALIDATION (no arbitrary market can ever be reached through this hook):
///      TickerRegistry is the single source of truth for which (token, market) pairs are real.
///      Since the currently-deployed TickerRegistry (the live HOOD canary) has no
///      token-address-keyed reverse lookup - only tokenOf(tokenId)/marketOf(tokenId), both keyed
///      by tokenId - this hook cannot query "is this token real" in O(1) directly against
///      TickerRegistry. Instead, `registerMarket(tokenId)` is a permissionless, one-time-per-token
///      function that reads TickerRegistry's own tokenOf/marketOf for that tokenId, and caches
///      the validated pair in this hook's own storage. Every subsequent swap looks up that cache,
///      not the raw PoolKey - a PoolKey referencing any token that was never validated this way
///      simply has no market to route to, and beforeSwap reverts. An attacker cannot register a
///      fake pair: registerMarket only ever trusts what TickerRegistry itself reports for that
///      tokenId, never caller-supplied addresses.
///
/// @dev CURRENCY ORDERING: PoolManager.initialize() requires currency0 < currency1, and native
///      ETH (address(0)) is the lowest possible address - so for every CLOG pool, currency0 is
///      always native ETH and currency1 is always the MemeToken. zeroForOne == true is always a
///      buy (ETH in, token out); zeroForOne == false is always a sell (token in, ETH out).
///      beforeSwap itself re-derives and checks this from the actual PoolKey on every call rather
///      than assuming it, so a malformed/malicious PoolKey (wrong currency0, e.g.) is rejected
///      explicitly rather than silently mishandled.
///
/// @dev EXACT INPUT ONLY: exact-output swaps (amountSpecified >= 0) are explicitly rejected. This
///      hook does not attempt to support exact-output "safely" via approximation - see the
///      project's own architecture notes for why: BondingCurveClog's own buy()/sell() take a
///      minimum-output/maximum-input style bound, not a target output, so satisfying an exact
///      OUTPUT would require this hook to iteratively search for the right input - genuinely
///      unsafe to do inside a single atomic hook callback with no established, audited pattern to
///      follow. Unsupported, not partially-supported.
///
/// @dev SETTLEMENT FLOW (verified empirically against real official v4-core/v4-periphery source,
///      with a real, unmodified BondingCurveClog, zero PoolManager liquidity, and zero prefunded
///      hook capital - see the accompanying test suite): a router constructs its actions as
///      SETTLE(exact input) -> SWAP_EXACT_IN_SINGLE -> TAKE_ALL(output), NOT the default
///      SWAP -> SETTLE -> TAKE ordering. Settling first means PoolManager physically holds the
///      swapper's real input by the time this hook's beforeSwap runs, so `poolManager.take()`
///      succeeds even though the pool itself has zero liquidity. This hook then calls the real
///      BondingCurveClog.buy()/sell(), deposits the real output back into PoolManager, and
///      returns a BeforeSwapDelta describing exactly what it did - which simultaneously drives
///      the underlying concentrated-liquidity math to a true no-op (PoolManager's own Pool.sol
///      returns a zero delta without reverting when the routed amount is exactly zero) and nets
///      this hook's own ledger position back to zero.
contract ClogV4Hook is IERC165 {
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;
    TickerRegistry public immutable tickerRegistry;

    /// @notice token address -> validated market address. Populated only by registerMarket,
    /// which only ever trusts TickerRegistry's own reported values for a given tokenId.
    mapping(address => address) public marketForToken;
    /// @notice tokenId -> whether registerMarket has already run for it (idempotency; harmless
    /// to call again, but this avoids a redundant TickerRegistry read on repeat calls).
    mapping(uint256 => bool) public tokenIdRegistered;

    /// @dev Minimal reentrancy guard around beforeSwap - PoolManager's own lock already prevents
    /// reentrancy into PoolManager itself during an active unlock, but this is a cheap,
    /// independent second layer directly on the hook's own state-changing entry point.
    uint256 private _reentrancyStatus = 1;

    event MarketRegistered(uint256 indexed tokenId, address indexed token, address indexed market);

    error OnlyPoolManager();
    error OnlyExactInputSupported();
    error UnregisteredMarket(address token);
    error InvalidPoolKey();
    error Reentrant();
    error AlreadyRegistered(uint256 tokenId);
    error NotYetLaunched(uint256 tokenId);
    error DeadlineExpired(uint256 deadline, uint256 currentTimestamp);

    modifier nonReentrant() {
        if (_reentrancyStatus == 2) revert Reentrant();
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    constructor(IPoolManager _poolManager, TickerRegistry _tickerRegistry) {
        poolManager = _poolManager;
        tickerRegistry = _tickerRegistry;
    }

    /// @notice The single source of truth for which v4 callbacks this hook implements - matches
    ///         the standard convention used by v4-periphery's own reference hooks (BaseHook-style
    ///         getHookPermissions), so a deployment script or test can mine/verify the correct
    ///         CREATE2 address directly from this declaration rather than a separately
    ///         maintained, potentially-drifting flag constant. This hook only ever implements
    ///         beforeSwap, and always returns a delta from it (required to make the underlying
    ///         concentrated-liquidity math a no-op - see the settlement-flow notes above) -
    ///         every other callback is deliberately false: this hook never touches liquidity,
    ///         donate, or afterSwap.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Mechanically derives the raw CREATE2 address flags from getHookPermissions() above
    ///         - the exact bits HookMiner needs to mine for, computed from the one declared
    ///         source of truth rather than duplicated as a separately maintained constant. A
    ///         deployment script or test calls this (via a fresh, throwaway instance, since it's
    ///         a pure function with no constructor dependency) to get the flags to mine against.
    function flagsFromPermissions() external pure returns (uint160 flags) {
        Hooks.Permissions memory p = getHookPermissions();
        if (p.beforeInitialize) flags |= uint160(Hooks.BEFORE_INITIALIZE_FLAG);
        if (p.afterInitialize) flags |= uint160(Hooks.AFTER_INITIALIZE_FLAG);
        if (p.beforeAddLiquidity) flags |= uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        if (p.afterAddLiquidity) flags |= uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG);
        if (p.beforeRemoveLiquidity) flags |= uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        if (p.afterRemoveLiquidity) flags |= uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        if (p.beforeSwap) flags |= uint160(Hooks.BEFORE_SWAP_FLAG);
        if (p.afterSwap) flags |= uint160(Hooks.AFTER_SWAP_FLAG);
        if (p.beforeDonate) flags |= uint160(Hooks.BEFORE_DONATE_FLAG);
        if (p.afterDonate) flags |= uint160(Hooks.AFTER_DONATE_FLAG);
        if (p.beforeSwapReturnDelta) flags |= uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        if (p.afterSwapReturnDelta) flags |= uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        if (p.afterAddLiquidityReturnDelta) flags |= uint160(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG);
        if (p.afterRemoveLiquidityReturnDelta) flags |= uint160(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
    }

    /// @notice Permissionless: validates and caches a (token, market) pair straight from
    /// TickerRegistry's own storage for a given tokenId. Anyone may call this for any real,
    /// launched tokenId - there is nothing to protect, since it can never register anything
    /// TickerRegistry itself didn't already establish. Idempotent in effect (a second call for
    /// the same tokenId reverts cleanly rather than silently no-op-ing, so a caller always knows
    /// whether their call actually did anything).
    function registerMarket(uint256 tokenId) external {
        if (tokenIdRegistered[tokenId]) revert AlreadyRegistered(tokenId);

        address token = tickerRegistry.tokenOf(tokenId);
        address market = tickerRegistry.marketOf(tokenId);
        // tokenOf/marketOf return the zero-value address(0) for any tokenId TickerRegistry never
        // actually launched - the real, authoritative "does this exist" signal, not a guess.
        if (token == address(0) || market == address(0)) revert NotYetLaunched(tokenId);

        tokenIdRegistered[tokenId] = true;
        marketForToken[token] = market;
        emit MarketRegistered(tokenId, token, market);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        if (params.amountSpecified >= 0) revert OnlyExactInputSupported();
        // Every CLOG pool has native ETH as currency0 by construction (see the contract-level
        // notes on currency ordering) - a PoolKey that doesn't satisfy this was never a real CLOG
        // pool this hook should trade against, regardless of what hooks address it names.
        if (!key.currency0.isAddressZero()) revert InvalidPoolKey();

        address token = Currency.unwrap(key.currency1);
        address market = marketForToken[token];
        if (market == address(0)) revert UnregisteredMarket(token);

        // User-controlled deadline, equivalent to the current direct-trade frontend's own
        // deadline semantics: hookData optionally carries a uint256 deadline (abi-encoded); an
        // empty hookData falls back to block.timestamp (the previous, always-trivially-satisfied
        // behavior) ONLY for callers that genuinely don't want deadline protection - any real
        // frontend integration should always supply one, exactly as it does for the direct path
        // today. BondingCurveClog's own `require(block.timestamp <= deadline, "expired")` is the
        // single source of truth that actually enforces this; the hook only decides what value
        // to forward.
        uint256 deadline = hookData.length == 32 ? abi.decode(hookData, (uint256)) : block.timestamp;
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);

        uint256 amountIn = uint256(-params.amountSpecified);

        if (params.zeroForOne) {
            return _executeBuy(key, BondingCurveClog(market), MemeToken(token), amountIn, deadline);
        } else {
            return _executeSell(key, BondingCurveClog(market), MemeToken(token), amountIn, deadline);
        }
    }

    function _executeBuy(
        PoolKey calldata key,
        BondingCurveClog market,
        MemeToken token,
        uint256 ethIn,
        uint256 deadline
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        // The router already settled ethIn into PoolManager (via the SETTLE action, before this
        // swap action ran) - PoolManager physically holds it, so this succeeds even though the
        // pool itself has zero liquidity of its own.
        poolManager.take(key.currency0, address(this), ethIn);

        // The real, unmodified, canonical economic transaction - the same buy() the direct
        // clog.run path calls, with the same eligibility touch, fee split, and CLOG-release
        // semantics. minTotalTokensOut is always 0 here - the router's own TAKE_ALL minAmount is
        // where slippage protection actually lives (matching v4's own standard pattern: the
        // router, not the pool/hook, enforces the user's minimum received), so this hook doesn't
        // duplicate that check with a second, independently-specified bound.
        uint256 tokensOut = market.buy{value: ethIn}(0, deadline);

        // sync() BEFORE the transfer, per DeltaResolver's own documented pattern (v4-periphery):
        // settle() computes the paid amount as the balance delta since the last sync, so sync
        // must snapshot the PRE-transfer balance.
        poolManager.sync(key.currency1);
        token.transfer(address(poolManager), tokensOut);
        poolManager.settle();

        BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(ethIn)), -int128(int256(tokensOut)));
        return (this.beforeSwap.selector, delta, 0);
    }

    function _executeSell(
        PoolKey calldata key,
        BondingCurveClog market,
        MemeToken token,
        uint256 tokenIn,
        uint256 deadline
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        poolManager.take(key.currency1, address(this), tokenIn);

        // Tightly scoped approval: exactly tokenIn, set immediately before the one call that
        // consumes it, for this specific market only - never a standing/unlimited approval, and
        // never shared across markets (each MemeToken/BondingCurveClog pair is a distinct
        // approval, scoped to this single trade's exact amount). BondingCurveClog.sell() pulls
        // exactly tokenIn via transferFrom, so the allowance is fully consumed by the call
        // itself; the explicit reset below is defense in depth against any future change to that
        // assumption, not a correction of an observed leftover.
        token.approve(address(market), tokenIn);
        (uint256 ethOut,) = market.sell(tokenIn, 0, deadline);
        if (token.allowance(address(this), address(market)) != 0) {
            token.approve(address(market), 0);
        }

        poolManager.sync(key.currency0);
        poolManager.settle{value: ethOut}();

        BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(tokenIn)), -int128(int256(ethOut)));
        return (this.beforeSwap.selector, delta, 0);
    }

    /// @notice URC-3 hook statistics interface (see v4-periphery's IHookStats) - purely
    /// informational, read-only, reports BondingCurveClog's real external reserve/effective
    /// liquidity for indexers (e.g. ReservesLens). Introduces no economic state of its own: every
    /// value returned here is read live from the canonical market, never cached or derived
    /// independently.
    function getReserves(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1) {
        address market = marketForToken[Currency.unwrap(key.currency1)];
        if (market == address(0)) return (0, 0);
        amount0 = BondingCurveClog(market).realReserve();
        amount1 = MemeToken(Currency.unwrap(key.currency1)).balanceOf(market);
    }

    function getEffectiveLiquidity(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1) {
        // For CLOG, the entire real reserve/remaining curve supply is always immediately
        // available to trade against (no locked/vesting portion within BondingCurveClog's own
        // accounting) - effective liquidity equals total reserves.
        return this.getReserves(key);
    }

    function hook() external view returns (address) {
        return address(this);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IHookStatsMinimal).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Quote surface for the frontend: an EXACT, zero-drift preview of what a real trade
    /// through this hook would produce, since it performs the identical validation and then
    /// delegates to BondingCurveClog's own buy()/sell() - never a second, independently
    /// maintained copy of the curve math. Intended to be called via eth_call (staticcall) from
    /// the frontend, exactly as the existing direct-trade quote flow already does against
    /// BondingCurveClog directly - this just adds the market-resolution step v4 callers need.
    /// Reverts (rather than returning a fabricated number) if the token was never registered.
    function quoteExactInput(address token, bool isBuy, uint256 amountIn) external payable returns (uint256 amountOut) {
        address marketAddr = marketForToken[token];
        if (marketAddr == address(0)) revert UnregisteredMarket(token);
        BondingCurveClog market = BondingCurveClog(marketAddr);
        if (isBuy) {
            amountOut = market.buy{value: amountIn}(0, block.timestamp);
        } else {
            MemeToken(token).approve(marketAddr, amountIn);
            (amountOut,) = market.sell(amountIn, 0, block.timestamp);
        }
        revert QuoteResult(amountOut);
    }

    /// @dev Quote results are returned via revert (the standard v4-periphery Quoter pattern -
    /// see BaseV4Quoter) specifically so quoteExactInput can safely call the real, state-changing
    /// buy()/sell() to get an exact answer, then unwind every state change unconditionally. A
    /// caller must invoke this via eth_call/staticcall and decode the revert data - never as a
    /// real transaction (a direct call would revert with no effect, by design).
    error QuoteResult(uint256 amountOut);

    receive() external payable {}
}

/// @dev Minimal duplicate of v4-periphery's IHookStats interface ID computation surface - avoids
/// pulling in the OpenZeppelin IERC165 version mismatch between this repo's existing OZ 5.0.2 and
/// v4-periphery's own OZ dependency, while still exposing the identical function selectors URC-3
/// requires. supportsInterface above answers true for this interface's id, matching what a real
/// IHookStats consumer (e.g. ReservesLens) checks for.
interface IHookStatsMinimal {
    function getReserves(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1);
    function getEffectiveLiquidity(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1);
    function hook() external view returns (address);
}
