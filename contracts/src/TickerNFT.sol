// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";

/// @title TickerNFT
/// @notice Each token ID represents economic ownership of one launched ticker's trading-fee
///         rights. Deliberately thin: OpenZeppelin ERC721 handles all ownership/approval/transfer
///         mechanics (do not hand-write any of that -- see REUSE BEFORE BUILD). The custom part is
///         narrow: only TickerRegistry can mint (one NFT per launched ticker, at launch time), and
///         there is no burn.
///
/// @dev THE key invariant this whole design exists to preserve: `ownerOf(tickerTokenId)` IS the
///      authoritative source of who receives that meme's future ticker-owner trading-fee share --
///      see BondingCurveClog, which resolves its fee recipient by calling `ownerOf` directly on
///      every trade rather than caching an address. There is no separate revenue-rights mapping to
///      keep in sync. Sell the NFT on OpenSea (or transfer it any other way) and the buyer becomes
///      the fee recipient the instant the transfer is confirmed on-chain -- no migration
///      transaction, no backend update, nothing else to do.
///
/// @dev METADATA: intentionally minimal for v1 -- a baseURI pointing at simple, static JSON
///      (ticker symbol, associated meme token/market address, launch timestamp) is enough for
///      OpenSea to index the collection. No on-chain dynamic renderer; see REUSE BEFORE BUILD --
///      building custom NFT metadata infrastructure isn't justified when a static JSON blob per
///      token, served from ordinary storage, satisfies the actual requirement.
/// @dev DEPLOYMENT: TickerNFT and TickerRegistry each need the other's address, which naively
///      creates a circular dependency -- same shape as MemeToken/BondingCurveClog, solved the same
///      way: deploy TickerNFT first (with a `deployer` allowed to initialize it, no registry set
///      yet), deploy TickerRegistry second (passing TickerNFT's real, already-known address), then
///      a one-time `setRegistry` call locks the registry permanently. No CREATE-nonce arithmetic,
///      no CREATE2, no prediction. Not an upgradeability pattern: there is no second call, ever,
///      to anyone, including the deployer or governance.
///
/// @dev SECONDARY-SALE ROYALTY (v2, ERC-2981): every TickerNFT advertises a 5% royalty
///      (500 / _feeDenominator()'s default 10_000) on secondary sales, paid entirely to the
///      protocol multisig, set once at construction via `_setDefaultRoyalty` and never
///      changeable afterward -- no external setter is exposed anywhere in this contract, by
///      design (see the task this was built for: "the V2 royalty should be fixed at deployment
///      rather than mutable by an EOA"). This is completely independent of every other revenue
///      stream in this protocol: the 0.002 ETH ticker launch fee (TickerRegistry), the 0.6%
///      meme-token trading tax and the ticker owner's 40% share of it (BondingCurveClog) are
///      unrelated flows this royalty neither reduces nor replaces. A 1 ETH secondary sale of
///      this NFT signals a 0.05 ETH royalty to multisig; the seller still receives the sale
///      proceeds, minus whatever the marketplace itself charges and minus that royalty, not
///      minus the royalty alone and not zero.
///
///      IMPORTANT LIMITATION, stated plainly rather than implied: ERC-2981 is a signaling
///      standard only. `royaltyInfo(tokenId, salePrice)` tells a marketplace what royalty
///      *should* be paid and to whom -- it does not, and structurally cannot, force any
///      marketplace, OTC transfer, or a plain `transferFrom` call to actually pay it. A
///      marketplace that doesn't honor ERC-2981, or a direct wallet-to-wallet transfer outside
///      any marketplace entirely, moves the NFT with zero royalty enforced by this contract or
///      by the chain itself. This contract deliberately does not attempt to work around that
///      limitation with transfer restrictions, an allowlist of "approved" marketplaces, or a
///      custom in-protocol marketplace of its own -- see REUSE BEFORE BUILD once more: that
///      would be a materially larger, more invasive piece of infrastructure than "advertise the
///      royalty correctly," which is the actual, complete scope of what ERC-2981 promises.
contract TickerNFT is ERC721, ERC2981 {
    /// @notice 5% of secondary sale price, under ERC-2981's default 10_000 denominator.
    uint96 public constant ROYALTY_BPS = 500;

    address public immutable deployer; // authorized to call setRegistry exactly once
    address public tickerRegistry; // address(0) until setRegistry is called; permanent afterward
    string private _baseTokenURI;

    event RegistryInitialized(address indexed registry);

    modifier onlyRegistry() {
        require(msg.sender == tickerRegistry, "not ticker registry");
        _;
    }

    constructor(string memory name_, string memory symbol_, address deployer_, string memory baseURI_, address multisig_)
        ERC721(name_, symbol_)
    {
        require(deployer_ != address(0), "zero deployer");
        require(multisig_ != address(0), "zero multisig");
        deployer = deployer_;
        _baseTokenURI = baseURI_;
        // Fixed at deployment, forever: no external setter exists anywhere in this contract to
        // change the receiver or the rate afterward, by the deployer, by governance, or by
        // anyone else.
        _setDefaultRoyalty(multisig_, ROYALTY_BPS);
    }

    /// @notice One-time initialization: sets the TickerRegistry address permanently. Callable
    ///         exactly once, only by `deployer`. No path exists to call this again, by anyone.
    function setRegistry(address registry_) external {
        require(msg.sender == deployer, "not deployer");
        require(tickerRegistry == address(0), "already initialized");
        require(registry_ != address(0), "zero registry");
        tickerRegistry = registry_;
        emit RegistryInitialized(registry_);
    }

    /// @notice Mints the ticker-ownership NFT for a newly launched ticker. Called exactly once per
    ///         ticker, by TickerRegistry, at launch time -- tokenId is the same id used throughout
    ///         EligibilityRegistry/BondingCurveClog for this meme, so all three stay trivially
    ///         cross-referenced by the same integer.
    function mint(address to, uint256 tokenId) external onlyRegistry {
        _safeMint(to, tokenId);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /// @dev Diamond-inheritance override required whenever a contract inherits from both ERC721
    ///      and ERC2981 (each declares its own supportsInterface). Chains through both parents'
    ///      implementations rather than picking one, so this token correctly advertises support
    ///      for IERC721/IERC721Metadata/IERC165 (from ERC721) AND IERC2981 (from ERC2981) alike.
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
