// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ClogMarket} from "./ClogMarket.sol";

/// @title ClogV4Hook (first vertical-slice version)
/// @notice Universal v4 execution adapter - pure v4 mechanics, no per-ticker economic state of
///         its own (see ClogMarket.sol). One instance shared by every CLOG ticker's pool.
///
/// @dev THE CORE MECHANISM THIS PROVES: PoolManager.swap() applies a hook's returned
///      BeforeSwapDelta to the hook's own account only AFTER afterSwap returns (verified
///      directly against Hooks.sol / PoolManager.sol source - see the conversation this was
///      built in). So mint()/burn() calls made HERE, inside beforeSwap, establish a real,
///      temporary hook delta immediately; the BeforeSwapDelta returned at the end of this
///      function must be engineered to exactly cancel that temporary delta once PoolManager
///      later applies it. Worked out algebraically (see docs below) and now proven by
///      test-v4/ClogV4HookBuySell.t.sol against the real, unmodified v4-core PoolManager.
///
/// @dev PER-MARKET ISOLATION: `marketOf[poolId]` is the ONLY source of truth for which
///      ClogMarket a swap on a given pool may touch - never derived from hookData (untrusted),
///      always from the actual PoolKey the swap is running against. This is what makes "every
///      market approves the same hook via ERC6909 approve()" safe: the hook's own logic, not
///      PoolManager, is the isolation boundary (see the conversation's own P0 isolation
///      discussion) - PoolId -> ClogMarket is registered once, at launch, before
///      PoolManager.initialize() is ever called for that pool (beforeInitialize enforces this
///      ordering explicitly).
///
/// @dev DELIBERATELY MINIMAL for this first slice: only exact-input swaps are handled: no
///      WinnerPot-direct-mint routing yet, no afterSwap logic, no cross-market isolation tests
///      yet (P0, still required before this can be trusted), no real hook-address flag mining
///      (tests use vm.etch onto a manually-constructed address with the right permission bits -
///      real deployment needs actual CREATE2 salt mining, not yet done).
contract ClogV4Hook is IHooks {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    address public immutable launchInitializer; // TickerRegistry (or equivalent) - the only caller allowed to registerMarket

    mapping(PoolId => address) public marketOf;

    event MarketRegistered(PoolId indexed poolId, address indexed market);

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not pool manager");
        _;
    }

    constructor(IPoolManager poolManager_, address launchInitializer_) {
        require(address(poolManager_) != address(0) && launchInitializer_ != address(0), "zero address");
        poolManager = poolManager_;
        launchInitializer = launchInitializer_;
    }

    /// @notice Registers the market for a not-yet-initialized pool. Callable once per poolId,
    ///         only by the launch initializer, and MUST happen before PoolManager.initialize()
    ///         is called for that pool - beforeInitialize (below) checks this is already set,
    ///         per the corrected atomic sequence: register -> initialize -> inventory deposit.
    function registerMarket(PoolKey calldata key, address market) external {
        require(msg.sender == launchInitializer, "not launch initializer");
        PoolId id = key.toId();
        require(marketOf[id] == address(0), "already registered");
        require(market != address(0), "zero market");
        marketOf[id] = market;
        emit MarketRegistered(id, market);
    }

    /// @notice `sender` (the original caller of PoolManager.initialize(), NOT msg.sender, which
    ///         is always PoolManager here) must be the authorized launch initializer, and the
    ///         market for this exact poolId must already be registered - otherwise an attacker
    ///         could initialize a CLOG-hooked pool at a price of their own choosing ahead of the
    ///         real launch.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        require(sender == launchInitializer, "not launch initializer");
        require(marketOf[key.toId()] != address(0), "market not registered");
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // NEVER derived from hookData (attacker-controlled) - always from the actual PoolKey
        // this swap is running against, matching the registry populated at launch.
        address market = marketOf[key.toId()];
        require(market != address(0), "unknown market");

        require(params.amountSpecified < 0, "only exact input supported in this slice");
        uint256 specifiedAmount = uint256(-params.amountSpecified);

        // Native ETH is always address(0), the lowest possible Currency value, so it is always
        // currency0 in any ETH/MemeToken pool - a safe, general assumption for this pairing,
        // not a coincidence specific to one pool.
        bool buyingToken = params.zeroForOne; // ETH (currency0) -> token (currency1)
        uint256 unspecifiedAmount;

        if (buyingToken) {
            uint256 tokensOut = ClogMarket(market).applyBuy(specifiedAmount);
            // Hook temporarily goes negative ETH (it just minted the market a claim for the
            // full specified input) and positive token (it just burned the market's own
            // pre-existing token claim to cover tokensOut) - see contract-level docs for why
            // the BeforeSwapDelta returned below must exactly cancel this.
            poolManager.mint(market, _currencyId(key.currency0), specifiedAmount);
            poolManager.burn(market, _currencyId(key.currency1), tokensOut);
            unspecifiedAmount = tokensOut;
        } else {
            uint256 ethOut = ClogMarket(market).applySell(specifiedAmount);
            poolManager.mint(market, _currencyId(key.currency1), specifiedAmount);
            poolManager.burn(market, _currencyId(key.currency0), ethOut);
            unspecifiedAmount = ethOut;
        }

        // Direction-independent in "specified"/"unspecified" terms (Hooks.sol's own afterSwap
        // wrapper handles the currency0/currency1 remapping based on zeroForOne/amountSpecified
        // sign - verified algebraically for both directions, see contract-level docs): the hook
        // always claims the full specified input and owes the unspecified output, cancelling
        // out the temporary mint/burn deltas above exactly.
        int128 specifiedDelta = int128(int256(specifiedAmount));
        int128 unspecifiedDelta = -int128(int256(unspecifiedAmount));

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedDelta, unspecifiedDelta), 0);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev A Currency's ERC6909 id is just its address, reinterpreted as uint256 - matches
    ///      CurrencyLibrary.toId() exactly (native ETH is address(0), so its id is 0).
    function _currencyId(Currency currency) internal pure returns (uint256) {
        return uint256(uint160(Currency.unwrap(currency)));
    }

    // ── Unused hook callbacks - no-ops, permission flags for these are never set ─────────────

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}
