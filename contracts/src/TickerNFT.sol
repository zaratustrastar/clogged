// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

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
contract TickerNFT is ERC721 {
    address public immutable deployer; // authorized to call setRegistry exactly once
    address public tickerRegistry; // address(0) until setRegistry is called; permanent afterward
    string private _baseTokenURI;

    event RegistryInitialized(address indexed registry);

    modifier onlyRegistry() {
        require(msg.sender == tickerRegistry, "not ticker registry");
        _;
    }

    constructor(string memory name_, string memory symbol_, address deployer_, string memory baseURI_)
        ERC721(name_, symbol_)
    {
        require(deployer_ != address(0), "zero deployer");
        deployer = deployer_;
        _baseTokenURI = baseURI_;
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
}
