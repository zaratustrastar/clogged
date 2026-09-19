// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MemeToken} from "./MemeToken.sol";
import {BondingCurveClog} from "./BondingCurveClog.sol";
import {TickerNFT} from "./TickerNFT.sol";

interface IEligibilityRegistryForLaunch {
    function nextTokenId() external view returns (uint256);
    function registerToken(address market) external returns (uint256 tokenId);
}

/// @title TickerRegistry
/// @notice The launch orchestrator: commit/reveal ticker claiming, atomic meme launch (MemeToken +
///         BondingCurveClog + TickerNFT + EligibilityRegistry registration, all in one
///         transaction), 7,777 public-ticker cap, permanent CLOG reservation.
///
/// @dev DEPLOYMENT ORDER, NO ADDRESS PREDICTION: same simple explicit flow as everywhere else in
///      this build -- deploy MemeToken (zero supply, no market), deploy BondingCurveClog passing
///      MemeToken's real address, then a one-time `setMarket` call that mints the full supply and
///      locks the market permanently. No CREATE-nonce arithmetic, no CREATE2, no clone factories.
///
/// @dev TICKER ID: EligibilityRegistry's `nextTokenId()` is used as the canonical id for this
///      launch (TickerNFT tokenId, BondingCurveClog's `tickerTokenId`, and the id
///      `registerToken` returns) -- a simple, deterministic counter read, asserted against
///      `registerToken`'s actual return value as a defensive check.
///
/// @dev COMMITMENT IDENTITY USES A FIXED-SIZE KEY, NOT A DYNAMIC STRING: the ticker is normalized
///      first, then reduced to `bytes32 tickerKey = keccak256(bytes(normalizedTicker))` --
///      everything that needs to identify a specific ticker (uniqueness, the CLOG reservation
///      check, and the commit/reveal hash itself) uses this fixed-size key internally. The
///      normalized string itself is kept only for display/metadata (`tickerOf`), never as part of
///      the commitment's own identity. This is a simplification, not a workaround for a specific
///      bug: fixed-size keys are simpler to reason about and audit than mixing dynamic `string`
///      values into `abi.encode`-based hash commitments.
///
/// @dev NORMALIZATION: ASCII uppercase letters only (A-Z after case-folding). Anything else --
///      digits, symbols, non-ASCII/Unicode bytes -- reverts. No homoglyph/confusable-character
///      detection: that is a materially harder problem than this product needs for v1, and an
///      ASCII-only alphabet has no homoglyphs to confuse in the first place.
///
/// @dev LAUNCH PAYMENT ROUTING: the full 0.002 ETH launch price goes 100% to multisig, 0% to
///      WinnerPot (v2 economics -- v1 split 10% multisig / 90% WinnerPot). The multisig leg is a
///      direct call that must succeed or the whole launch reverts -- a launch reverting because
///      the payment leg failed costs the user nothing (the whole transaction reverts, ETH stays
///      theirs) and they can simply retry -- unlike continuous trading, a one-time,
///      user-initiated, freely-retriable action doesn't need BondingCurveClog's pending/retry
///      WinnerPot liveness pattern. `winnerPot` itself is still a required constructor
///      dependency and still passed to every newly-created BondingCurveClog market (trading tax
///      revenue still funds RewardVault directly) -- only the launch-fee leg changed.
contract TickerRegistry is ReentrancyGuard {
    uint256 public constant MAX_PUBLIC_TICKERS = 7_777;
    uint256 public constant LAUNCH_PRICE = 0.002 ether;
    uint256 public constant MIN_TICKER_LENGTH = 2;
    uint256 public constant MAX_TICKER_LENGTH = 10;
    uint256 public constant MIN_REVEAL_DELAY = 60; // seconds -- minimal anti-frontrunning window
    uint256 public constant REVEAL_WINDOW = 1 days; // reveal must happen within this long after the delay

    uint256 public constant MULTISIG_LAUNCH_BPS = 10_000; // 100%
    uint256 public constant BPS = 10_000;

    bytes32 public constant RESERVED_CLOG_KEY = keccak256(bytes("CLOG"));

    IEligibilityRegistryForLaunch public immutable eligibilityRegistry;
    TickerNFT public immutable tickerNFT;
    address public immutable multisig;
    address public immutable winnerPot;
    address public immutable governance; // passed through to each BondingCurveClog as its governance
    uint256 public immutable virtualEthSeed;
    uint256 public immutable bufferBps;

    uint256 public publicTickerCount;

    mapping(bytes32 => uint256) public commitTimestamp; // 0 = no active commitment
    mapping(bytes32 => bool) public tickerKeyTaken; // tickerKey -> taken
    mapping(uint256 => string) public tickerOf; // tokenId -> display string, for metadata/UI only
    mapping(uint256 => address) public marketOf;
    mapping(uint256 => address) public tokenOf;

    event Committed(address indexed sender, bytes32 commitHash);
    event Launched(address indexed sender, uint256 indexed tokenId, string ticker, address market, address token);

    constructor(
        address eligibilityRegistry_,
        address tickerNFT_,
        address multisig_,
        address winnerPot_,
        address governance_,
        uint256 virtualEthSeed_,
        uint256 bufferBps_
    ) {
        require(
            eligibilityRegistry_ != address(0) && tickerNFT_ != address(0) && multisig_ != address(0)
                && winnerPot_ != address(0) && governance_ != address(0),
            "TickerRegistry: zero address"
        );
        eligibilityRegistry = IEligibilityRegistryForLaunch(eligibilityRegistry_);
        tickerNFT = TickerNFT(tickerNFT_);
        multisig = multisig_;
        winnerPot = winnerPot_;
        governance = governance_;
        virtualEthSeed = virtualEthSeed_;
        bufferBps = bufferBps_;
    }

    /// @notice Step 1 of commit/reveal. `commitHash` should be
    ///         `keccak256(abi.encode(msg.sender, tickerKey, salt))` where
    ///         `tickerKey = keccak256(bytes(normalizedTicker))` (see `tickerKeyOf`), computed
    ///         off-chain, so the ticker itself stays hidden until reveal.
    function commit(bytes32 commitHash) external {
        require(commitTimestamp[commitHash] == 0, "TickerRegistry: already committed");
        commitTimestamp[commitHash] = block.timestamp;
        emit Committed(msg.sender, commitHash);
    }

    /// @notice Step 2: reveals the ticker, pays the launch price, and atomically launches the
    ///         associated meme (MemeToken + BondingCurveClog + TickerNFT mint + EligibilityRegistry
    ///         registration) if everything checks out.
    function reveal(string calldata ticker, bytes32 salt) external payable nonReentrant returns (uint256 tokenId) {
        string memory normalized = _normalize(ticker);
        bytes32 tickerKey = keccak256(bytes(normalized));
        require(tickerKey != RESERVED_CLOG_KEY, "TickerRegistry: CLOG is reserved");
        require(!tickerKeyTaken[tickerKey], "TickerRegistry: ticker taken");

        bytes32 commitHash = keccak256(abi.encode(msg.sender, tickerKey, salt));
        uint256 committedAt = commitTimestamp[commitHash];
        require(committedAt != 0, "TickerRegistry: no matching commitment");
        require(block.timestamp >= committedAt + MIN_REVEAL_DELAY, "TickerRegistry: reveal too early");
        require(block.timestamp <= committedAt + MIN_REVEAL_DELAY + REVEAL_WINDOW, "TickerRegistry: reveal expired");
        delete commitTimestamp[commitHash]; // replay protection: this specific commitment is now spent

        require(msg.value == LAUNCH_PRICE, "TickerRegistry: wrong payment");
        require(publicTickerCount < MAX_PUBLIC_TICKERS, "TickerRegistry: public ticker cap reached");
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
        tokenId = eligibilityRegistry.nextTokenId(); // deterministic counter read, not a CREATE prediction

        BondingCurveClog market = new BondingCurveClog(
            address(token),
            address(tickerNFT),
            tokenId,
            multisig,
            winnerPot,
            governance,
            address(eligibilityRegistry),
            virtualEthSeed,
            bufferBps
        );
        token.setMarket(address(market)); // one-time: mints the full 1B supply, locks the market forever

        uint256 registeredId = eligibilityRegistry.registerToken(address(market));
        require(registeredId == tokenId, "TickerRegistry: token id mismatch");

        marketOf[tokenId] = address(market);
        tokenOf[tokenId] = address(token);
    }

    function _routeLaunchPayment() internal {
        uint256 toMultisig = (LAUNCH_PRICE * MULTISIG_LAUNCH_BPS) / BPS;
        uint256 toWinnerPot = LAUNCH_PRICE - toMultisig;
        (bool ok1,) = multisig.call{value: toMultisig}("");
        require(ok1, "TickerRegistry: multisig payment failed");
        // v2: toWinnerPot is 0 at the current MULTISIG_LAUNCH_BPS (100%) -- skip the call
        // entirely rather than making a pointless zero-value external call. Kept general
        // (not hardcoded to "always skip") so a future split change needs only the constant.
        if (toWinnerPot > 0) {
            (bool ok2,) = winnerPot.call{value: toWinnerPot}("");
            require(ok2, "TickerRegistry: winnerPot payment failed");
        }
    }

    /// @dev ASCII-only: uppercases a-z, passes through A-Z, reverts on anything else (digits,
    ///      symbols, non-ASCII/Unicode bytes). No homoglyph detection -- see the contract-level
    ///      developer notes above.
    function _normalize(string memory input) internal pure returns (string memory) {
        bytes memory b = bytes(input);
        require(
            b.length >= MIN_TICKER_LENGTH && b.length <= MAX_TICKER_LENGTH, "TickerRegistry: invalid ticker length"
        );
        bytes memory out = new bytes(b.length);
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 0x61 && c <= 0x7A) {
                out[i] = bytes1(c - 32); // a-z -> A-Z
            } else if (c >= 0x41 && c <= 0x5A) {
                out[i] = bytes1(c); // already A-Z
            } else {
                revert("TickerRegistry: invalid character");
            }
        }
        return string(out);
    }

    /// @notice Pure view helper so front-ends/tests can normalize off-chain before committing.
    function normalize(string calldata ticker) external pure returns (string memory) {
        return _normalize(ticker);
    }

    /// @notice Pure view helper: the fixed-size key a given (possibly unnormalized) ticker string
    ///         reduces to -- what commitments, uniqueness, and the CLOG check are keyed on.
    function tickerKeyOf(string calldata ticker) external pure returns (bytes32) {
        return keccak256(bytes(_normalize(ticker)));
    }

    /// @notice Whether a given ticker string (any case) is still available to launch.
    function isAvailable(string calldata ticker) external view returns (bool) {
        bytes32 key = keccak256(bytes(_normalize(ticker)));
        return key != RESERVED_CLOG_KEY && !tickerKeyTaken[key];
    }
}
