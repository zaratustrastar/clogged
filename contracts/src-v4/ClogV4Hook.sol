// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ClogMarket} from "./ClogMarket.sol";

/// @notice Minimal interface into RewardVault's own accounting hook - kept separate from
///         importing RewardVault.sol directly to avoid pulling its full dependency graph
///         (ReentrancyGuard, Math, its own v4-core imports) into this contract's compilation
///         unit just for one function call.
interface IRewardVaultRecorder {
    function recordWinnerPotClaim(uint256 amount) external;
}

/// @notice Minimal ERC20 interface for reading the market's balance during the launch-time
///         inventory deposit - see unlockCallback's REQUEST_DEPOSIT branch.
interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}

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
contract ClogV4Hook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;
    address public immutable launchInitializer; // TickerRegistry (or equivalent) - the only caller allowed to registerMarket
    address public rewardVault; // WinnerPot's own claim-native destination - see beforeSwap's mint-split.
        // NOT immutable and NOT a constructor param, deliberately: RewardVault's own constructor
        // needs this hook's address (to authenticate recordWinnerPotClaim), so requiring this
        // hook to already know RewardVault's address at construction time would create a
        // circular CREATE/CREATE2 dependency - especially fragile here since this hook's own
        // address must additionally satisfy CREATE2 permission-bit mining. Deployment order
        // instead: mine/deploy this hook -> deploy RewardVault(roundManager, poolManager,
        // address(thisHook)) -> call setRewardVault(rewardVault) here exactly once -> only then
        // is registerMarket/trading permitted (both check rewardVault != address(0) below). This
        // is one-time deployment initialization, not ongoing upgradeability: there is no path to
        // change it again afterward.

    mapping(PoolId => address) public marketOf;
    mapping(address => PoolId) public poolOf; // reverse relationship - a market may be registered to at most one pool, ever

    event MarketRegistered(PoolId indexed poolId, address indexed market);
    event RewardVaultConfigured(address indexed rewardVault);

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not pool manager");
        _;
    }

    constructor(IPoolManager poolManager_, address launchInitializer_) {
        require(address(poolManager_) != address(0) && launchInitializer_ != address(0), "zero address");
        poolManager = poolManager_;
        launchInitializer = launchInitializer_;
    }

    /// @notice One-time deployment initialization, called exactly once after RewardVault has
    ///         been deployed (which itself needed this hook's address already) - breaks the
    ///         constructor cycle described above. Deliberately NOT governance-updatable: no
    ///         function anywhere changes rewardVault after this succeeds once.
    function setRewardVault(address rewardVault_) external {
        require(msg.sender == launchInitializer, "not launch initializer");
        require(rewardVault_ != address(0), "zero reward vault");
        require(rewardVault == address(0), "already configured");
        rewardVault = rewardVault_;
        emit RewardVaultConfigured(rewardVault_);
    }

    /// @notice Registers the market for a not-yet-initialized pool. Callable once per poolId,
    ///         only by the launch initializer, and MUST happen before PoolManager.initialize()
    ///         is called for that pool - beforeInitialize (below) checks this is already set,
    ///         per the corrected atomic sequence: register -> initialize -> inventory deposit.
    ///
    /// @dev Does NOT rely on the launch initializer being honest to maintain the PoolKey/market
    ///      binding invariant - validates the actual relationship directly, since an
    ///      authorized-but-malformed call (a real bug in the launch flow, not just an external
    ///      attacker) must be caught here too:
    ///        - key.hooks must be this exact hook (a market registered against a DIFFERENT
    ///          hook's PoolKey would never actually be reachable via this hook's own beforeSwap,
    ///          but rejecting it here catches the mistake at registration time, not silently);
    ///        - key.currency0 must be native ETH (address(0)) - the only pairing this
    ///          architecture supports;
    ///        - key.currency1 must be EXACTLY the market's own token() - never a different
    ///          token paired against someone else's market;
    ///        - the market's own hook() must be this exact hook - a market deployed pointing at
    ///          a different (or no) hook could never legitimately authorize trades through this
    ///          one, since its own onlyHook modifier would reject every call;
    ///        - the market must never have been registered to any other PoolId before (poolOf) -
    ///          one market, one pool, permanently.
    function registerMarket(PoolKey calldata key, address market) external {
        require(msg.sender == launchInitializer, "not launch initializer");
        require(rewardVault != address(0), "reward vault not configured");
        require(market != address(0), "zero market");
        require(address(key.hooks) == address(this), "PoolKey hook mismatch");
        require(Currency.unwrap(key.currency0) == address(0), "currency0 must be native ETH");
        require(key.currency1 == Currency.wrap(ClogMarket(market).token()), "PoolKey currency1 must be exactly the market's own token");
        require(ClogMarket(market).hook() == address(this), "market's own hook must be this hook");

        PoolId id = key.toId();
        require(marketOf[id] == address(0), "already registered");
        require(PoolId.unwrap(poolOf[market]) == bytes32(0), "market already registered to a different pool");

        marketOf[id] = market;
        poolOf[market] = id;
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
        // Defense in depth: registerMarket already refuses to run until rewardVault is
        // configured, so no market could exist yet if this were ever false in practice - kept
        // here anyway so beforeSwap's own requirements are self-evident without having to trace
        // registerMarket's ordering to see why this is always safe.
        require(rewardVault != address(0), "reward vault not configured");

        require(params.amountSpecified < 0, "only exact input supported in this slice");
        uint256 specifiedAmount = uint256(-params.amountSpecified);

        // Native ETH is always address(0), the lowest possible Currency value, so it is always
        // currency0 in any ETH/MemeToken pool - a safe, general assumption for this pairing,
        // not a coincidence specific to one pool.
        bool buyingToken = params.zeroForOne; // ETH (currency0) -> token (currency1)
        uint256 unspecifiedAmount;

        if (buyingToken) {
            (uint256 tokensOut, uint256 winnerPotShare) = ClogMarket(market).applyBuy(specifiedAmount);
            // CLAIM-NATIVE WinnerPot SPLIT: the market receives only the portion backing its own
            // realETH + owner/multisig liabilities; WinnerPot's own share is minted DIRECTLY to
            // RewardVault's own ERC6909 claim, never touching the market's claim at all, with
            // recordWinnerPotClaim called SYNCHRONOUSLY in this same transaction so a later,
            // separate allocateRound() call is guaranteed to see it (see RewardVault.sol's own
            // docs on why this rules out a keeper-flush race entirely).
            uint256 marketPortion = specifiedAmount - winnerPotShare;
            poolManager.mint(market, _currencyId(key.currency0), marketPortion);
            if (winnerPotShare > 0) {
                poolManager.mint(rewardVault, _currencyId(key.currency0), winnerPotShare);
                IRewardVaultRecorder(rewardVault).recordWinnerPotClaim(winnerPotShare);
            }
            // Hook temporarily goes negative ETH (it just minted marketPortion+winnerPotShare,
            // together summing to the full specified input, across the market and RewardVault)
            // and positive token (it just burned the market's own pre-existing token claim to
            // cover tokensOut) - see contract-level docs for why the BeforeSwapDelta returned
            // below must exactly cancel this: it only ever references specifiedAmount as a
            // whole, so splitting who receives it makes no difference to that cancellation.
            poolManager.burn(market, _currencyId(key.currency1), tokensOut);
            unspecifiedAmount = tokensOut;
        } else {
            (uint256 netEthOut, uint256 winnerPotShare, bool wasCapped) = ClogMarket(market).applySell(specifiedAmount);
            wasCapped; // informational only in this slice - not yet surfaced to the router/event layer
            poolManager.mint(market, _currencyId(key.currency1), specifiedAmount);
            poolManager.burn(market, _currencyId(key.currency0), netEthOut);
            // Same claim-native split as the buy side above: the market's own ETH claim must
            // never retain WinnerPot's share, so an EXTRA, independent burn+mint pair (self-
            // cancelling for the hook's own delta, entirely separate from the
            // specifiedAmount/unspecifiedAmount pair the BeforeSwapDelta below accounts for)
            // moves exactly winnerPotShare from the market straight to RewardVault.
            if (winnerPotShare > 0) {
                poolManager.burn(market, _currencyId(key.currency0), winnerPotShare);
                poolManager.mint(rewardVault, _currencyId(key.currency0), winnerPotShare);
                IRewardVaultRecorder(rewardVault).recordWinnerPotClaim(winnerPotShare);
            }
            unspecifiedAmount = netEthOut;
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

    /// @notice Called by a registered market's own withdraw(to) to convert `amount` of that
    ///         market's ERC6909 ETH claim into real native ETH, sent directly to `to`.
    ///         Restricted to registered markets calling on their own behalf - msg.sender IS the
    ///         market whose own claim gets burned, never an arbitrary caller naming an arbitrary
    ///         market/amount, since this hook holds blanket per-currency ERC6909 approval from
    ///         every registered market and that trust must never be redirectable by anyone else.
    uint8 internal constant REQUEST_WITHDRAWAL = 1;
    uint8 internal constant REQUEST_DEPOSIT = 2;

    function executeWithdrawal(address to, uint256 amount) external {
        require(PoolId.unwrap(poolOf[msg.sender]) != bytes32(0), "not a registered market");
        require(to != address(0), "zero recipient");
        require(amount > 0, "zero amount");
        poolManager.unlock(abi.encode(REQUEST_WITHDRAWAL, abi.encode(msg.sender, to, amount)));
    }

    /// @notice Part of the atomic launch sequence (see TickerRegistryV4.sol's own _launchMeme):
    ///         deposits `market`'s ENTIRE real token balance (the full physical supply
    ///         MemeToken.setMarket just minted to it) into PoolManager and mints the market a
    ///         matching ERC6909 claim for exactly that amount, in one unlock() round-trip.
    ///         Restricted to launchInitializer - the same authorization boundary as
    ///         registerMarket, since this is part of the same trusted, one-time launch flow, and
    ///         the actual token movement itself is further gated by ClogMarket's own onlyHook
    ///         check on depositInventoryTo (this function calls it as the hook, the only caller
    ///         that function accepts).
    function depositMarketInventory(address market, address tokenAddress, PoolKey calldata key) external {
        require(msg.sender == launchInitializer, "not launch initializer");
        require(marketOf[key.toId()] == market, "market/key mismatch");
        poolManager.unlock(abi.encode(REQUEST_DEPOSIT, abi.encode(market, tokenAddress, key)));
    }

    /// @notice IUnlockCallback - exclusively reached via executeWithdrawal or
    ///         depositMarketInventory above (the swap flow's own unlock() call is made by the
    ///         ROUTER, never by this hook, so this is never invoked mid-swap). A single leading
    ///         kind byte discriminates the two request shapes.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (uint8 kind, bytes memory inner) = abi.decode(data, (uint8, bytes));

        if (kind == REQUEST_WITHDRAWAL) {
            // Burns exactly `amount` of `market`'s own ETH claim and takes the same amount out
            // as real native ETH directly to `to` - burn (+amount delta for this hook) and take
            // (-amount delta) cancel exactly, leaving a net-zero delta with no separate sync/
            // settle step needed here, unlike a swap where an external router settles its own
            // side. take() itself reverts (NativeTransferFailed) if `to` cannot receive the
            // ETH, which reverts this entire call atomically - the liability
            // ClogMarket.withdraw already cleared is restored along with everything else, never
            // silently lost.
            (address market, address to, uint256 amount) = abi.decode(inner, (address, address, uint256));
            poolManager.burn(market, _currencyId(Currency.wrap(address(0))), amount);
            poolManager.take(Currency.wrap(address(0)), to, amount);
        } else if (kind == REQUEST_DEPOSIT) {
            // Real launch-time inventory deposit: sync PoolManager's own view of the token,
            // have the market transfer its ENTIRE real balance in (via its own onlyHook-gated
            // depositInventoryTo, called by this hook), settle, then mint the market an ERC6909
            // claim for exactly that amount - the market's claim is now fully backed by a real,
            // physical deposit, exactly as this profile's own tests have proven the mechanism
            // works throughout (ClogV4HookBuySell.t.sol and others), just via a real function
            // call here instead of a test-only vm.prank.
            (address market, address tokenAddress, PoolKey memory key) = abi.decode(inner, (address, address, PoolKey));
            uint256 balance = IERC20Like(tokenAddress).balanceOf(market);
            require(balance > 0, "nothing to deposit");
            poolManager.sync(key.currency1);
            ClogMarket(market).depositInventoryTo(tokenAddress, address(poolManager));
            poolManager.settle();
            poolManager.mint(market, _currencyId(key.currency1), balance);
        } else {
            revert("unknown unlock request kind");
        }

        return "";
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
