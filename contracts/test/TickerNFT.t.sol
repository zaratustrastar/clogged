// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickerNFT} from "../src/TickerNFT.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice ERC-2981 secondary-sale royalty behavior, plus confirmation the royalty addition
/// changes nothing about TickerNFT's existing ownership/transfer semantics or the
/// ticker-owner trading-fee redirect that depends on ownerOf() (see BondingCurveClog).
contract TickerNFTTest is Test {
    TickerNFT nft;

    address deployer = address(this);
    address multisig = address(0xA51);
    address alice = address(0xA11CE);
    address bob = address(0xB0B1);

    function setUp() public {
        nft = new TickerNFT("Ticker", "TICK", deployer, "https://example.com/metadata/", multisig);
        nft.setRegistry(deployer); // this test contract acts as TickerRegistry for mint()
    }

    // ── Constructor validation ───────────────────────────────────────────────

    function test_constructor_zeroMultisigRejected() public {
        vm.expectRevert();
        new TickerNFT("Ticker", "TICK", deployer, "https://example.com/metadata/", address(0));
    }

    // ── Task's own required cases ────────────────────────────────────────────

    function test_royaltyInfo_oneEther_fivePercentToMultisig() public {
        nft.mint(alice, 1);
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, multisig, "royalty receiver must be the protocol multisig");
        assertEq(amount, 0.05 ether, "royalty must be exactly 5% of a 1 ETH sale price");
    }

    function test_royaltyInfo_arbitrarySalePrice() public {
        nft.mint(alice, 1);
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 37 ether);
        assertEq(receiver, multisig);
        assertEq(amount, 1.85 ether, "5% of 37 ETH is exactly 1.85 ETH");
    }

    function test_royaltyInfo_zeroSalePrice() public {
        nft.mint(alice, 1);
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 0);
        assertEq(receiver, multisig, "receiver is still reported even for a zero sale price");
        assertEq(amount, 0, "5% of zero is zero, not a revert or an error");
    }

    function test_supportsInterface_erc2981() public view {
        assertTrue(nft.supportsInterface(type(IERC2981).interfaceId), "must advertise ERC-2981 support");
        // Sanity: the royalty addition must not have broken ERC-721's own interface
        // advertisement (a real diamond-inheritance override bug would show up here).
        assertTrue(nft.supportsInterface(type(IERC721).interfaceId), "must still advertise ERC-721 support");
    }

    function test_transfer_stillWorksNormally() public {
        nft.mint(alice, 1);
        assertEq(nft.ownerOf(1), alice);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        assertEq(nft.ownerOf(1), bob, "ownership must transfer normally, exactly as before this task");
    }

    function test_transfer_doesNotChangeRoyaltyRecipient() public {
        nft.mint(alice, 1);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        (address receiver, uint256 amount) = nft.royaltyInfo(1, 1 ether);
        assertEq(receiver, multisig, "royalty recipient stays the protocol multisig regardless of who owns the NFT");
        assertEq(amount, 0.05 ether, "royalty rate is unaffected by ownership transfer too");
    }

    /// @notice Royalty is a flat, contract-wide default (no per-token override is ever set) -
    ///         confirmed across several distinct token ids, including ones never minted at all.
    ///         royaltyInfo is a pure signal, not gated on the token's existence, matching
    ///         ERC-2981's own real semantics (it takes no position on whether tokenId is valid).
    function test_royaltyInfo_sameAcrossEveryTokenId() public {
        nft.mint(alice, 1);
        nft.mint(alice, 2);
        (address r1, uint256 a1) = nft.royaltyInfo(1, 10 ether);
        (address r2, uint256 a2) = nft.royaltyInfo(2, 10 ether);
        (address r3, uint256 a3) = nft.royaltyInfo(999, 10 ether); // never minted
        assertEq(r1, multisig);
        assertEq(r2, multisig);
        assertEq(r3, multisig);
        assertEq(a1, 0.5 ether);
        assertEq(a2, 0.5 ether);
        assertEq(a3, 0.5 ether);
    }

    /// @notice No external royalty setter exists anywhere on this contract - the royalty is
    ///         fixed for the life of the contract, by design (task requirement: "the V2 royalty
    ///         should be fixed at deployment rather than mutable by an EOA"). There is no
    ///         function selector to even attempt calling - this test documents that by
    ///         confirming the only way royaltyInfo's result ever changes is a brand new
    ///         TickerNFT deployment with a different multisig_ constructor argument.
    function test_royalty_fixedAtDeployment_differsOnlyAcrossDeployments() public {
        address otherMultisig = address(0xB0B5157);
        TickerNFT otherNft = new TickerNFT("Ticker2", "TICK2", deployer, "https://example.com/metadata/", otherMultisig);
        (address receiver,) = otherNft.royaltyInfo(1, 1 ether);
        assertEq(receiver, otherMultisig, "a different deployment's own constructor argument is the only way the receiver differs");

        // The original nft instance is completely unaffected by the second deployment.
        (address originalReceiver,) = nft.royaltyInfo(1, 1 ether);
        assertEq(originalReceiver, multisig);
    }
}
