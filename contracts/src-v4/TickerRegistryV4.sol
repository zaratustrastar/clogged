// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {ClogMarket} from "./ClogMarket.sol";
import {ClogV4Hook} from "./ClogV4Hook.sol";

interface ITickerNFTForV4Launch {
    function mint(address to, uint256 tokenId) external;
}

interface IEligibilityRegistryForV4Launch {
    function nextTokenId() external view returns (uint256);
    function registerToken(address market) external returns (uint256 tokenId);
}

/// @title TickerRegistryV4
/// @notice The v4 launch orchestrator - the atomic-launch counterpart of production
///         TickerRegistry.sol (read directly before writing this, not from memory), adapted for
///         v4: commit/reveal ticker claiming is IDENTICAL, but the atomic launch itself deploys
///         a non-custodial ClogMarket, registers it with the (already-deployed, already CREATE2-
///         mined) universal ClogV4Hook, initializes its PoolManager pool, and deposits its full
///         physical supply into PoolManager - all in the SAME transaction as the reveal itself,
///         exactly matching v2's own "atomic launch, no address prediction" property.
///
/// @dev DELIBERATELY A SEPARATE CONTRACT, NOT A MODIFICATION OF PRODUCTION TickerRegistry.sol:
///      TickerNFT's own setRegistry is a ONE-TIME lock (confirmed directly against source before
///      designing this) - a single TickerNFT collection can only ever be authorized to one
///      registry, ever. This contract therefore uses its OWN, separate TickerNFT collection
///      (constructor param, already deployed but not yet had setRegistry called - this
///      contract's own deployer must call TickerNFT.setRegistry(address(thisContract)) exactly
///      once as part of setup, exactly mirroring how ClogV4Hook.setRewardVault works). This is
///      the correct shape for a v4 canary/migration period running alongside v2, not a
///      replacement for it - EligibilityRegistry, by contrast, is NOT single-registry-locked
///      (registerToken has no caller restriction, confirmed directly against source), so it MAY
///      be shared with v2 or kept separate, at the deployer's own choice via the constructor.
///
/// @dev DEPLOYMENT ORDER (no address prediction anywhere, no circular CREATE/CREATE2
///      dependency): deploy this contract first (constructor needs no v4 infrastructure at
///      all - poolManager/hook/rewardVault are NOT constructor params, precisely because this
///      contract's own address must be known BEFORE the hook can be mined, since the hook's own
///      constructor needs launchInitializer = address(this)) -> mine/deploy ClogV4Hook with
///      launchInitializer = address(thisContract) -> deploy RewardVault(roundManager,
///      poolManager, hookAddress) -> deploy this v4 system's own TickerNFT (setRegistry not yet
///      called) -> call setV4Infrastructure(poolManager, hook, rewardVault) on this contract
///      (only this contract's own deployer may call it, exactly once - it also calls
///      hook.setRewardVault(rewardVault) as part of the same step, since this contract IS the
///      hook's launchInitializer and no other caller could) -> TickerNFT.setRegistry(address(
///      thisContract)) -> only then does reveal() actually succeed. Both one-time external
///      initializations (setV4Infrastructure and TickerNFT.setRegistry) are enforced
///      TRANSITIVELY beyond reveal()'s own explicit poolManager check: hook.registerMarket
///      (called from _launchMeme) already requires hook.rewardVault != address(0) on its own,
///      and tickerNFT.mint (called at the very end of reveal()) already requires
///      tickerNFT.tickerRegistry == address(this) on its own.
contract TickerRegistryV4 is ReentrancyGuard {
    uint256 public constant MAX_PUBLIC_TICKERS = 7_777;
    uint256 public constant LAUNCH_PRICE = 0.002 ether;
    uint256 public constant MIN_TICKER_LENGTH = 2;
    uint256 public constant MAX_TICKER_LENGTH = 10;
    uint256 public constant MIN_REVEAL_DELAY = 60;
    uint256 public constant REVEAL_WINDOW = 1 days;

    uint256 public constant MULTISIG_LAUNCH_BPS = 10_000; // 100%, identical split to v2 at launch
    uint256 public constant BPS = 10_000;

    bytes32 public constant RESERVED_CLOG_KEY = keccak256(bytes("CLOG"));

    IEligibilityRegistryForV4Launch public immutable eligibilityRegistry;
    ITickerNFTForV4Launch public immutable tickerNFT;
    address public immutable multisig;
    uint256 public immutable virtualEthSeed;
    uint256 public immutable bufferBps;
    address public immutable deployer; // authorizes the one-time setV4Infrastructure call only - no other privilege

    // NOT immutable, NOT constructor params, deliberately - see setV4Infrastructure's own docs
    // for why: this contract must be deployable BEFORE the hook exists at all (the hook's own
    // constructor needs THIS contract's address as launchInitializer), so requiring these at
    // construction time would recreate exactly the circular CREATE/CREATE2 dependency already
    // fixed once for the hook<->RewardVault relationship - the same fix applies here.
    IPoolManager public poolManager;
    ClogV4Hook public hook;
    address public rewardVault; // launch-fee WinnerPot leg pushes here directly, exactly like v2's own winnerPot push - unrelated to per-trade claim-native routing

    uint256 public publicTickerCount;

    mapping(bytes32 => uint256) public commitTimestamp;
    mapping(bytes32 => bool) public tickerKeyTaken;
    mapping(uint256 => string) public tickerOf;
    mapping(uint256 => address) public marketOf;
    mapping(uint256 => address) public tokenOf;

    event Committed(address indexed sender, bytes32 commitHash);
    event Launched(address indexed sender, uint256 indexed tokenId, string ticker, address market, address token);
    event V4InfrastructureConfigured(address poolManager, address hook, address rewardVault);

    constructor(
        address eligibilityRegistry_,
        address tickerNFT_,
        address multisig_,
        uint256 virtualEthSeed_,
        uint256 bufferBps_
    ) {
        require(
            eligibilityRegistry_ != address(0) && tickerNFT_ != address(0) && multisig_ != address(0),
            "TickerRegistryV4: zero address"
        );
        eligibilityRegistry = IEligibilityRegistryForV4Launch(eligibilityRegistry_);
        tickerNFT = ITickerNFTForV4Launch(tickerNFT_);
        multisig = multisig_;
        virtualEthSeed = virtualEthSeed_;
        bufferBps = bufferBps_;
        deployer = msg.sender;
    }

    /// @notice One-time deployment initialization, called AFTER the hook has been mined and
    ///         deployed with launchInitializer = address(this) - breaks the circular
    ///         construction dependency described above, mirroring ClogV4Hook.setRewardVault's
    ///         own one-time pattern exactly. Since this contract IS the hook's own
    ///         launchInitializer, only it can call hook.setRewardVault - done here, as part of
    ///         this same one-time step, so a caller only ever needs to remember one
    ///         initialization call, not two separately-ordered ones.
    function setV4Infrastructure(address poolManager_, address hook_, address rewardVault_) external {
        require(msg.sender == deployer, "not deployer");
        require(address(poolManager) == address(0), "already configured");
        require(poolManager_ != address(0) && hook_ != address(0) && rewardVault_ != address(0), "zero address");
        poolManager = IPoolManager(poolManager_);
        hook = ClogV4Hook(hook_);
        rewardVault = rewardVault_;
        hook.setRewardVault(rewardVault_);
        emit V4InfrastructureConfigured(poolManager_, hook_, rewardVault_);
    }

    function commit(bytes32 commitHash) external {
        require(commitTimestamp[commitHash] == 0, "TickerRegistryV4: already committed");
        commitTimestamp[commitHash] = block.timestamp;
        emit Committed(msg.sender, commitHash);
    }

    /// @notice Step 2: reveals the ticker, pays the launch price, and atomically launches the
    ///         v4 meme (MemeToken + ClogMarket + hook registration + pool initialization +
    ///         inventory deposit + hook approvals + TickerNFT mint + EligibilityRegistry
    ///         registration) if everything checks out - identical commit/reveal semantics to
    ///         production TickerRegistry.sol, only the launch core differs.
    function reveal(string calldata ticker, bytes32 salt) external payable nonReentrant returns (uint256 tokenId) {
        require(address(poolManager) != address(0), "TickerRegistryV4: v4 infrastructure not configured");
        string memory normalized = _normalize(ticker);
        bytes32 tickerKey = keccak256(bytes(normalized));
        require(tickerKey != RESERVED_CLOG_KEY, "TickerRegistryV4: CLOG is reserved");
        require(!tickerKeyTaken[tickerKey], "TickerRegistryV4: ticker taken");

        bytes32 commitHash = keccak256(abi.encode(msg.sender, tickerKey, salt));
        uint256 committedAt = commitTimestamp[commitHash];
        require(committedAt != 0, "TickerRegistryV4: no matching commitment");
        require(block.timestamp >= committedAt + MIN_REVEAL_DELAY, "TickerRegistryV4: reveal too early");
        require(block.timestamp <= committedAt + MIN_REVEAL_DELAY + REVEAL_WINDOW, "TickerRegistryV4: reveal expired");
        delete commitTimestamp[commitHash];

        require(msg.value == LAUNCH_PRICE, "TickerRegistryV4: wrong payment");
        require(publicTickerCount < MAX_PUBLIC_TICKERS, "TickerRegistryV4: public ticker cap reached");
        publicTickerCount++;
        tickerKeyTaken[tickerKey] = true;

        tokenId = _launchMeme(normalized);

        tickerOf[tokenId] = normalized;
        emit Launched(msg.sender, tokenId, normalized, marketOf[tokenId], tokenOf[tokenId]);

        _routeLaunchPayment();
        tickerNFT.mint(msg.sender, tokenId);
    }

    function _launchMeme(string memory normalized) internal returns (uint256 tokenId) {
        MemeToken token = new MemeToken(normalized, normalized, address(this));
        tokenId = eligibilityRegistry.nextTokenId();

        ClogMarket market = new ClogMarket(
            address(hook), address(token), address(tickerNFT), tokenId, multisig, virtualEthSeed, bufferBps
        );
        token.setMarket(address(market)); // mints the full 1B supply, locks the market forever

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Corrected atomic sequence, identical ordering to every other proof in this profile:
        // register BEFORE initialize (beforeInitialize checks this), initialize, THEN deposit -
        // the market never holds its own supply for longer than this one transaction takes.
        hook.registerMarket(key, address(market));
        poolManager.initialize(key, _initialSqrtPriceX96());
        hook.depositMarketInventory(address(market), address(token), key);
        market.grantHookApprovals(address(poolManager));

        uint256 registeredId = eligibilityRegistry.registerToken(address(market));
        require(registeredId == tokenId, "TickerRegistryV4: token id mismatch");

        marketOf[tokenId] = address(market);
        tokenOf[tokenId] = address(token);
    }

    /// @dev sqrtPriceX96 for a nominal price of 1 (irrelevant to actual trading - the curve is
    ///      fully hook-driven, exactly as documented throughout this profile's other tests).
    function _initialSqrtPriceX96() internal pure returns (uint160) {
        return 79228162514264337593543950336;
    }

    function _routeLaunchPayment() internal {
        uint256 toMultisig = (LAUNCH_PRICE * MULTISIG_LAUNCH_BPS) / BPS;
        uint256 toWinnerPot = LAUNCH_PRICE - toMultisig;
        (bool ok1,) = multisig.call{value: toMultisig}("");
        require(ok1, "TickerRegistryV4: multisig payment failed");
        if (toWinnerPot > 0) {
            (bool ok2,) = rewardVault.call{value: toWinnerPot}("");
            require(ok2, "TickerRegistryV4: rewardVault payment failed");
        }
    }

    function _normalize(string memory input) internal pure returns (string memory) {
        bytes memory b = bytes(input);
        require(b.length >= MIN_TICKER_LENGTH && b.length <= MAX_TICKER_LENGTH, "TickerRegistryV4: invalid ticker length");
        bytes memory out = new bytes(b.length);
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 0x61 && c <= 0x7A) {
                out[i] = bytes1(c - 32);
            } else if (c >= 0x41 && c <= 0x5A) {
                out[i] = bytes1(c);
            } else {
                revert("TickerRegistryV4: invalid character");
            }
        }
        return string(out);
    }
}
