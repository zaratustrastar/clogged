// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal stand-in for TickerNFT, implementing only what BondingCurveClog needs
/// (ownerOf). Lets tests control ticker ownership directly without going through the full
/// commit-reveal launch flow -- that flow gets its own dedicated TickerRegistry tests.
contract MockTickerNFT {
    mapping(uint256 => address) public ownerOf;

    function setOwner(uint256 tokenId, address owner) external {
        ownerOf[tokenId] = owner;
    }
}
