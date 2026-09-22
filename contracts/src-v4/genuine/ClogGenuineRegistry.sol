// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ClogMarket} from "../ClogMarket.sol";
import {ClogGenuineMath} from "./ClogGenuineMath.sol";
import {ClogGenuineLiquidityHook} from "./ClogGenuineLiquidityHook.sol";

interface IMemeTokenG {
    function setMarket(address market) external;
}

interface ITickerNFTG {
    function mint(address to, uint256 tokenId) external;
}

/// @title ClogGenuineRegistry
/// @notice Atomic launch for the genuine-liquidity architecture.
///
///   The 0.002 ETH launch fee goes 100% to the Safe, in full, in the same call. The Registry
///   retains NOTHING and the WinnerPot receives NOTHING from the launch fee - the WinnerPot is
///   funded only by trading tax and extracted CLOG revenue, which is unchanged.
///
///   The pool is initialized at the canonical launch price and the hook mints the single
///   token-only SINGLE_BOUNDARY position: ZERO protocol ETH.
contract ClogGenuineRegistry {
    uint256 public constant LAUNCH_PRICE = 0.002 ether;

    /// @notice Set once, at construction, to the deployer. The ONLY account that may call
    ///         setV4Infrastructure, and only while the infrastructure is still unset. There is
    ///         deliberately no transfer, no upgrade path and no way to reconfigure afterwards.
    address public immutable configurator;

    address public immutable safe;
    address public immutable tickerNFT;
    address public immutable multisig;
    address public immutable eligibilityRegistry;
    uint256 public immutable virtualEthSeed;
    uint256 public immutable bufferMultiplierBps;

    IPoolManager public poolManager;
    ClogGenuineLiquidityHook public hook;
    address public rewardVault;

    uint256 public nextTokenId = 1;
    mapping(uint256 => address) public marketOf;
    mapping(uint256 => address) public tokenOf;

    event Launched(uint256 indexed tokenId, address token, address market, address launcher, uint256 fee);

    error NotConfigurator();
    error AlreadyConfigured();
    error ZeroAddress();
    error WrongFee();
    error FeeTransferFailed();
    error NotConfigured();

    constructor(
        address safe_,
        address tickerNFT_,
        address multisig_,
        address eligibilityRegistry_,
        uint256 virtualEthSeed_,
        uint256 bufferMultiplierBps_
    ) {
        configurator = msg.sender;
        safe = safe_;
        tickerNFT = tickerNFT_;
        multisig = multisig_;
        eligibilityRegistry = eligibilityRegistry_;
        virtualEthSeed = virtualEthSeed_;
        bufferMultiplierBps = bufferMultiplierBps_;
    }

    /// @notice One-shot infrastructure wiring, callable only by the configurator.
    /// @dev Previously unguarded: anyone could re-point poolManager/hook/rewardVault, and since
    ///      hook.setRewardVault is onlyRegistry that allowed redirecting the WinnerPot. Now it
    ///      is configurator-only AND single-use. hook.setRewardVault stays onlyRegistry.
    function setV4Infrastructure(address pm, address hook_, address vault) external {
        if (msg.sender != configurator) revert NotConfigurator();
        if (
            address(poolManager) != address(0) || address(hook) != address(0)
                || rewardVault != address(0)
        ) revert AlreadyConfigured();
        if (pm == address(0) || hook_ == address(0) || vault == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(pm);
        hook = ClogGenuineLiquidityHook(payable(hook_));
        rewardVault = vault;
        hook.setRewardVault(vault);
    }

    /// @notice Deploy token + market, register and initialize the pool, mint the TickerNFT and
    ///         establish the token-only position - atomically, for exactly 0.002 ETH to the Safe.
    /// @param token a freshly deployed MemeToken whose launcher is this Registry
    function launch(address token, int24 tickSpacing) external payable returns (uint256 tokenId, address market) {
        if (address(poolManager) == address(0) || address(hook) == address(0)) revert NotConfigured();
        if (msg.value != LAUNCH_PRICE) revert WrongFee();

        tokenId = nextTokenId++;

        market = address(
            new ClogMarket(
                address(hook), token, tickerNFT, tokenId, multisig,
                virtualEthSeed, bufferMultiplierBps, eligibilityRegistry
            )
        );
        IMemeTokenG(token).setMarket(market);
        ClogMarket(market).grantHookApprovals(address(poolManager));

        ITickerNFTG(tickerNFT).mint(msg.sender, tokenId);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });

        hook.registerPool(key, market, virtualEthSeed);
        uint256 re = ClogMarket(market).re();
        uint256 rt = ClogMarket(market).rt();
        poolManager.initialize(key, ClogGenuineMath.sqrtPriceX96Of(re, rt));
        hook.launch(key, re, rt);

        marketOf[tokenId] = market;
        tokenOf[tokenId] = token;

        // 100% of the fee to the Safe. Registry keeps nothing; WinnerPot gets nothing.
        (bool ok,) = safe.call{value: LAUNCH_PRICE}("");
        if (!ok) revert FeeTransferFailed();

        emit Launched(tokenId, token, market, msg.sender, LAUNCH_PRICE);
    }
}
