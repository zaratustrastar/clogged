// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChainlinkRandomnessProvider} from "../src/ChainlinkRandomnessProvider.sol";
import {VRFWrapperOnArbitrum} from "../src/VRFWrapperOnArbitrum.sol";

/// @title WireCrossChain
/// @notice Run once both DeployRobinhoodChain.s.sol and DeployArbitrumWrapper.s.sol have completed
///         and their addresses are known. Both remaining wiring calls
///         (ChainlinkRandomnessProvider.setWrapper on Robinhood Chain,
///         VRFWrapperOnArbitrum.setProvider on Arbitrum One) are governance-gated on their
///         respective chains, so this script does not execute anything itself -- it only logs the
///         exact target + calldata for each, ready to queue through the relevant timelock/Safe.
///
/// @dev A read-only sanity check IS run here (view calls only): confirming both addresses
///      resolve to real, deployed contracts before anyone queues a governance action against
///      them, so a copy-paste address error surfaces immediately rather than as a wasted 48-hour
///      timelock cycle.
contract WireCrossChain is Script {
    function run() external view {
        address providerAddr = vm.envAddress("CHAINLINK_RANDOMNESS_PROVIDER");
        address wrapperAddr = vm.envAddress("VRF_WRAPPER_ON_ARBITRUM");

        // Sanity checks only -- these confirm code exists at each address on whichever chain this
        // script is pointed at via --rpc-url; run it once per chain to validate that side's
        // address before queuing the corresponding governance action.
        require(providerAddr.code.length > 0, "WireCrossChain: provider has no code on this chain");
        require(wrapperAddr.code.length > 0, "WireCrossChain: wrapper has no code on this chain");

        console2.log("=== Cross-chain wiring: required governance actions ===");
        console2.log("On Robinhood Chain, queue through the timelock (proposer: the Safe):");
        console2.log("  target:", providerAddr);
        console2.log("  calldata:");
        console2.logBytes(abi.encodeCall(ChainlinkRandomnessProvider.setWrapper, (wrapperAddr)));
        console2.log("");
        console2.log("On Arbitrum One, queue via wrapper's owner (must have already called acceptOwnership()):");
        console2.log("  target:", wrapperAddr);
        console2.log("  calldata:");
        console2.logBytes(abi.encodeCall(VRFWrapperOnArbitrum.setProvider, (providerAddr)));
        console2.log("");
        console2.log("The protocol cannot resolve any draw until BOTH of these have executed.");
    }
}
