// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ClogMarket} from "./ClogMarket.sol";

interface IRewardVaultRecorderV2 {
    function recordWinnerPotClaim(uint256 amount) external;
}

interface IERC20LikeV2 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title ClogV4HookV2 (production candidate - NOT deployed)
/// @notice Universal CLOG hook with an externally observable Uniswap v4 price.
///
///   ECONOMICS: beforeSwap is V1's ClogV4Hook.beforeSwap unchanged - 100% of every user swap is
///   absorbed via BeforeSwapDelta, ClogMarket computes the result, and the core AMM never prices
///   a user trade. User result, CLOG state, taxes, owner/multisig/WinnerPot amounts and ERC6909
///   claims are identical to V1 by construction.
///
///   OBSERVABILITY: afterSwap then issues exactly ONE nested core swap against the protocol's
///   own sentinel liquidity, bounded by sqrtPriceLimitX96 = sqrt(rt/re)*2^96, so slot0 lands
///   EXACTLY on the canonical CLOG price (proven for L = 0 .. 1e21). The nested swap never calls
///   back into this hook: pinned v4.0.0 Hooks.beforeSwap/afterSwap return early when
///   msg.sender == hook. `_calibrating` is defense-in-depth only.
///
///   FUNDING: calibration is paid ONLY from the per-pool operating-fund ledger
///   (operatingFundEth / operatingFundToken). v4 sign semantics (verified against pinned
///   source): negative delta = hook owes PoolManager, positive = PoolManager owes hook.
///     amount0 < 0: require ledgerEth >= |a0|, debit, settle ETH;  amount0 > 0: take ETH, credit
///     amount1 < 0: require ledgerTok >= |a1|, debit, settle token; amount1 > 0: take token, credit
///   Insufficient ledger reverts the whole outer swap atomically (incl. ClogMarket, MemeToken
///   TWAB and EligibilityRegistry state).
///
///   LIQUIDITY: BEFORE_ADD_LIQUIDITY / BEFORE_REMOVE_LIQUIDITY gate every pool this hook
///   governs. PoolManager passes `sender` = the address that called PoolManager.modifyLiquidity
///   (i.e. the unlock holder / router), never an EOA-supplied value. The hook's OWN
///   modifyLiquidity calls skip these callbacks entirely (v4 noSelfCall), so any invocation that
///   reaches them is by definition an outsider and is rejected. The only path by which the hook
///   itself modifies liquidity is modifySentinel(), restricted to the immutable sentinelManager,
///   always on the single fixed full-range position (fixed ticks + fixed salt), so it cannot be
///   duplicated. The sentinel never prices a user trade (beforeSwap consumes 100%), so it is
///   not a trading path.
///
///   MASK: BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | BEFORE_SWAP |
///         AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA = 0x2AC8 (verified from Hooks.sol constants).
contract ClogV4HookV2 is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    address public immutable launchInitializer;
    address public immutable sentinelManager;
    address public rewardVault;

    mapping(PoolId => address) public marketOf;
    mapping(address => PoolId) public poolOf;

    mapping(PoolId => uint256) public operatingFundEth;
    mapping(PoolId => uint256) public operatingFundToken;
    mapping(PoolId => uint128) public sentinelLiquidity;
    uint256 public totalOperatingFundEth; // sum over pools; raw ETH balance must always cover it

    bool private _calibrating;

    int24 public constant SENTINEL_TICK_LOWER = -887220; // full range, multiples of tickSpacing 60
    int24 public constant SENTINEL_TICK_UPPER = 887220;
    bytes32 public constant SENTINEL_SALT = keccak256("CLOG_V2_SENTINEL");
    int24 public constant TICK_SPACING = 60;

    uint8 internal constant REQUEST_WITHDRAWAL = 1;
    uint8 internal constant REQUEST_DEPOSIT = 2;
    uint8 internal constant REQUEST_SENTINEL = 3;

    event MarketRegistered(PoolId indexed poolId, address indexed market);
    event RewardVaultConfigured(address indexed rewardVault);
    event Calibrated(PoolId indexed poolId, int128 amount0, int128 amount1, uint160 sqrtPriceX96);
    event SentinelModified(PoolId indexed poolId, int256 liquidityDelta, int128 amount0, int128 amount1, uint128 newLiquidity);
    event OperatingFundDeposited(PoolId indexed poolId, address indexed from, uint256 eth, uint256 token);
    event OperatingFundWithdrawn(PoolId indexed poolId, address indexed to, uint256 eth, uint256 token);

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not pool manager");
        _;
    }

    modifier onlySentinelManager() {
        require(msg.sender == sentinelManager, "not sentinel manager");
        _;
    }

    constructor(IPoolManager poolManager_, address launchInitializer_, address sentinelManager_) {
        require(
            address(poolManager_) != address(0) && launchInitializer_ != address(0) && sentinelManager_ != address(0),
            "zero address"
        );
        poolManager = poolManager_;
        launchInitializer = launchInitializer_;
        sentinelManager = sentinelManager_;
    }

    // ── Launch wiring (identical to V1) ─────────────────────────────────────────────────────

    function setRewardVault(address rewardVault_) external {
        require(msg.sender == launchInitializer, "not launch initializer");
        require(rewardVault_ != address(0), "zero reward vault");
        require(rewardVault == address(0), "already configured");
        rewardVault = rewardVault_;
        emit RewardVaultConfigured(rewardVault_);
    }

    function registerMarket(PoolKey calldata key, address market) external {
        require(msg.sender == launchInitializer, "not launch initializer");
        require(rewardVault != address(0), "reward vault not configured");
        require(market != address(0), "zero market");
        require(address(key.hooks) == address(this), "PoolKey hook mismatch");
        require(Currency.unwrap(key.currency0) == address(0), "currency0 must be native ETH");
        require(key.currency1 == Currency.wrap(ClogMarket(market).token()), "PoolKey currency1 must be exactly the market's own token");
        require(ClogMarket(market).hook() == address(this), "market's own hook must be this hook");
        require(key.fee == 0 && key.tickSpacing == TICK_SPACING, "fee must be 0, tickSpacing 60");

        PoolId id = key.toId();
        require(marketOf[id] == address(0), "already registered");
        require(PoolId.unwrap(poolOf[market]) == bytes32(0), "market already registered to a different pool");
        marketOf[id] = market;
        poolOf[market] = id;
        emit MarketRegistered(id, market);
    }

    /// @notice Canonical CLOG price as a v4 sqrtPriceX96: sqrt(currency1/currency0) =
    ///         sqrt(rt/re) * 2^96, clamped into TickMath's valid range.
    function canonicalSqrtPriceX96(address market) public view returns (uint160) {
        uint256 s = Math.sqrt(Math.mulDiv(ClogMarket(market).rt(), 1 << 192, ClogMarket(market).re()));
        if (s < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (s >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(s);
    }

    // ── Hook callbacks ──────────────────────────────────────────────────────────────────────

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external view onlyPoolManager returns (bytes4) {
        require(sender == launchInitializer, "not launch initializer");
        address market = marketOf[key.toId()];
        require(market != address(0), "market not registered");
        require(sqrtPriceX96 == canonicalSqrtPriceX96(market), "initial price must be the canonical CLOG price");
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        require(sender == address(this), "liquidity is protocol-managed");
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        require(sender == address(this), "liquidity is protocol-managed");
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (_calibrating) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        address market = marketOf[key.toId()];
        require(market != address(0), "unknown market");
        require(rewardVault != address(0), "reward vault not configured");
        require(params.amountSpecified < 0, "only exact input supported");
        uint256 specifiedAmount = uint256(-params.amountSpecified);
        uint256 unspecifiedAmount;

        if (params.zeroForOne) {
            (uint256 tokensOut, uint256 winnerPotShare) = ClogMarket(market).applyBuy(specifiedAmount);
            poolManager.mint(market, _id(key.currency0), specifiedAmount - winnerPotShare);
            if (winnerPotShare > 0) {
                poolManager.mint(rewardVault, _id(key.currency0), winnerPotShare);
                IRewardVaultRecorderV2(rewardVault).recordWinnerPotClaim(winnerPotShare);
            }
            poolManager.burn(market, _id(key.currency1), tokensOut);
            unspecifiedAmount = tokensOut;
        } else {
            (uint256 netEthOut, uint256 winnerPotShare,) = ClogMarket(market).applySell(specifiedAmount);
            poolManager.mint(market, _id(key.currency1), specifiedAmount);
            poolManager.burn(market, _id(key.currency0), netEthOut);
            if (winnerPotShare > 0) {
                poolManager.burn(market, _id(key.currency0), winnerPotShare);
                poolManager.mint(rewardVault, _id(key.currency0), winnerPotShare);
                IRewardVaultRecorderV2(rewardVault).recordWinnerPotClaim(winnerPotShare);
            }
            unspecifiedAmount = netEthOut;
        }

        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(int128(int256(specifiedAmount)), -int128(int256(unspecifiedAmount))),
            0
        );
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (_calibrating) return (IHooks.afterSwap.selector, 0);
        PoolId id = key.toId();
        uint160 target = canonicalSqrtPriceX96(marketOf[id]);
        (uint160 current,,,) = poolManager.getSlot0(id);
        if (target != current) {
            _calibrating = true;
            _calibrate(key, id, target, target < current);
            _calibrating = false;
        }
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev Runs inside the outer unlock session (swap/sync/settle/take need only an active
    ///      session; unlock() is not re-entered). zeroForOne moves sqrtPrice down (verified).
    function _calibrate(PoolKey calldata key, PoolId id, uint160 target, bool zeroForOne) internal {
        BalanceDelta d = poolManager.swap(
            key, IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e30, sqrtPriceLimitX96: target}), ""
        );
        _settleEth(key, id, d.amount0());
        _settleToken(key, id, d.amount1());
        require(address(this).balance >= totalOperatingFundEth, "ETH ledger not backed");
        require(IERC20LikeV2(Currency.unwrap(key.currency1)).balanceOf(address(this)) >= operatingFundToken[id], "token ledger not backed");
        (uint160 landed,,,) = poolManager.getSlot0(id);
        require(landed == target, "calibration did not land on target");
        emit Calibrated(id, d.amount0(), d.amount1(), landed);
    }

    function _settleEth(PoolKey calldata key, PoolId id, int128 a0) internal {
        if (a0 < 0) {
            uint256 owed = uint256(int256(-a0));
            require(operatingFundEth[id] >= owed, "operating fund ETH insufficient");
            operatingFundEth[id] -= owed;
            totalOperatingFundEth -= owed;
            poolManager.sync(key.currency0);
            poolManager.settle{value: owed}();
        } else if (a0 > 0) {
            uint256 received = uint256(int256(a0));
            poolManager.take(key.currency0, address(this), received);
            operatingFundEth[id] += received;
            totalOperatingFundEth += received;
        }
    }

    function _settleToken(PoolKey calldata key, PoolId id, int128 a1) internal {
        if (a1 < 0) {
            uint256 owed = uint256(int256(-a1));
            require(operatingFundToken[id] >= owed, "operating fund token insufficient");
            operatingFundToken[id] -= owed;
            poolManager.sync(key.currency1);
            require(IERC20LikeV2(Currency.unwrap(key.currency1)).transfer(address(poolManager), owed), "token transfer failed");
            poolManager.settle();
        } else if (a1 > 0) {
            uint256 received = uint256(int256(a1));
            poolManager.take(key.currency1, address(this), received);
            operatingFundToken[id] += received;
        }
    }

    // ── Operating fund (explicit, separate from sentinel capital) ───────────────────────────

    /// @notice Explicit operating-fund contribution for a registered pool: all of msg.value and
    ///         exactly `tokenAmount` (pulled via transferFrom) are credited to that pool's ledger.
    ///         Permissionless on purpose (anyone may top up liveness funds); withdrawal is
    ///         sentinelManager-only.
    function depositOperatingFund(PoolKey calldata key, uint256 tokenAmount) external payable {
        PoolId id = key.toId();
        require(marketOf[id] != address(0), "unknown market");
        if (tokenAmount > 0) {
            require(IERC20LikeV2(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), tokenAmount), "token pull failed");
            operatingFundToken[id] += tokenAmount;
        }
        operatingFundEth[id] += msg.value;
        totalOperatingFundEth += msg.value;
        emit OperatingFundDeposited(id, msg.sender, msg.value, tokenAmount);
    }

    function withdrawOperatingFund(PoolKey calldata key, uint256 ethAmount, uint256 tokenAmount, address to) external onlySentinelManager {
        PoolId id = key.toId();
        require(to != address(0), "zero recipient");
        require(operatingFundEth[id] >= ethAmount && operatingFundToken[id] >= tokenAmount, "exceeds ledger");
        operatingFundEth[id] -= ethAmount;
        totalOperatingFundEth -= ethAmount;
        operatingFundToken[id] -= tokenAmount;
        if (tokenAmount > 0) require(IERC20LikeV2(Currency.unwrap(key.currency1)).transfer(to, tokenAmount), "token transfer failed");
        if (ethAmount > 0) {
            (bool ok,) = to.call{value: ethAmount}("");
            require(ok, "eth transfer failed");
        }
        emit OperatingFundWithdrawn(id, to, ethAmount, tokenAmount);
    }

    // ── Sentinel (sentinelManager only; single fixed full-range position per pool) ──────────

    /// @notice Adds (liquidityDelta > 0) or removes (< 0) sentinel liquidity. Adds are paid from
    ///         msg.value (ETH, exact PoolManager-reported amount; any excess is REFUNDED to the
    ///         caller - never silently credited anywhere) and transferFrom(caller) for token.
    ///         Removals send recovered ETH/token to the caller. Requires slot0 == canonical price.
    function modifySentinel(PoolKey calldata key, int256 liquidityDelta)
        external
        payable
        onlySentinelManager
        returns (int128 amount0, int128 amount1)
    {
        PoolId id = key.toId();
        address market = marketOf[id];
        require(market != address(0), "unknown market");
        require(liquidityDelta != 0, "zero liquidityDelta");
        if (liquidityDelta < 0) {
            require(msg.value == 0, "no ETH on removal");
            require(uint256(-liquidityDelta) <= sentinelLiquidity[id], "exceeds sentinel liquidity");
        }
        (uint160 current,,,) = poolManager.getSlot0(id);
        require(current == canonicalSqrtPriceX96(market), "slot0 not at canonical price");

        uint256 ethBefore = address(this).balance - msg.value;
        BalanceDelta d = abi.decode(
            poolManager.unlock(abi.encode(REQUEST_SENTINEL, abi.encode(key, liquidityDelta, msg.sender))), (BalanceDelta)
        );
        amount0 = d.amount0();
        amount1 = d.amount1();

        sentinelLiquidity[id] = liquidityDelta > 0
            ? sentinelLiquidity[id] + uint128(uint256(liquidityDelta))
            : sentinelLiquidity[id] - uint128(uint256(-liquidityDelta));

        // The add must be paid entirely by msg.value - never by ledger-backed ETH.
        require(address(this).balance >= ethBefore, "msg.value below sentinel ETH cost");
        // Refund any msg.value not consumed by the add (removal ETH was already sent to caller).
        uint256 excess = address(this).balance - ethBefore;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            require(ok, "refund failed");
        }
        require(address(this).balance >= totalOperatingFundEth, "ETH ledger not backed");
        emit SentinelModified(id, liquidityDelta, amount0, amount1, sentinelLiquidity[id]);
    }

    // ── Market withdrawal / launch deposit (identical to V1) + sentinel unlock path ─────────

    function executeWithdrawal(address to, uint256 amount) external {
        require(PoolId.unwrap(poolOf[msg.sender]) != bytes32(0), "not a registered market");
        require(to != address(0), "zero recipient");
        require(amount > 0, "zero amount");
        poolManager.unlock(abi.encode(REQUEST_WITHDRAWAL, abi.encode(msg.sender, to, amount)));
    }

    function depositMarketInventory(address market, address tokenAddress, PoolKey calldata key) external {
        require(msg.sender == launchInitializer, "not launch initializer");
        require(marketOf[key.toId()] == market, "market/key mismatch");
        poolManager.unlock(abi.encode(REQUEST_DEPOSIT, abi.encode(market, tokenAddress, key)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (uint8 kind, bytes memory inner) = abi.decode(data, (uint8, bytes));

        if (kind == REQUEST_WITHDRAWAL) {
            (address market, address to, uint256 amount) = abi.decode(inner, (address, address, uint256));
            poolManager.burn(market, 0, amount);
            poolManager.take(Currency.wrap(address(0)), to, amount);
            return "";
        }
        if (kind == REQUEST_DEPOSIT) {
            (address market, address tokenAddress, PoolKey memory key) = abi.decode(inner, (address, address, PoolKey));
            uint256 balance = IERC20LikeV2(tokenAddress).balanceOf(market);
            require(balance > 0, "nothing to deposit");
            poolManager.sync(key.currency1);
            ClogMarket(market).depositInventoryTo(tokenAddress, address(poolManager));
            poolManager.settle();
            poolManager.mint(market, _id(key.currency1), balance);
            return "";
        }
        require(kind == REQUEST_SENTINEL, "unknown unlock request kind");
        (PoolKey memory k, int256 liquidityDelta, address counterparty) = abi.decode(inner, (PoolKey, int256, address));
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({tickLower: SENTINEL_TICK_LOWER, tickUpper: SENTINEL_TICK_UPPER, liquidityDelta: liquidityDelta, salt: SENTINEL_SALT}),
            ""
        );
        if (d.amount0() < 0) {
            poolManager.sync(k.currency0);
            poolManager.settle{value: uint256(int256(-d.amount0()))}();
        } else if (d.amount0() > 0) {
            poolManager.take(k.currency0, counterparty, uint256(int256(d.amount0())));
        }
        if (d.amount1() < 0) {
            uint256 owed = uint256(int256(-d.amount1()));
            address tokenAddr = Currency.unwrap(k.currency1);
            poolManager.sync(k.currency1);
            require(IERC20LikeV2(tokenAddr).transferFrom(counterparty, address(poolManager), owed), "sentinel token pull failed");
            poolManager.settle();
        } else if (d.amount1() > 0) {
            poolManager.take(k.currency1, counterparty, uint256(int256(d.amount1())));
        }
        return abi.encode(d);
    }

    function _id(Currency c) internal pure returns (uint256) {
        return uint256(uint160(Currency.unwrap(c)));
    }

    /// @dev Required: PoolManager.take() delivers native ETH here during SELL calibration, and
    ///      sentinel adds receive msg.value. ETH arriving any other way is NOT credited to any
    ///      ledger (it cannot fund calibration) - see the report's residual-risk list.
    receive() external payable {}

    // ── Flags this hook never sets - unreachable, revert defensively ────────────────────────

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert("unused");
    }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert("unused");
    }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert("unused");
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("unused");
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert("unused");
    }
}
