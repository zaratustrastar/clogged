// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VRFWrapperOnArbitrum} from "../src/VRFWrapperOnArbitrum.sol";

/// @title DeployArbitrumWrapper
/// @notice Deploys VRFWrapperOnArbitrum on Arbitrum One and points its ownership at governance.
///         Run AFTER DeployRobinhoodChain.s.sol (this script needs the ChainlinkRandomnessProvider
///         address from that deployment) and BEFORE WireCrossChain.s.sol.
///
/// @dev OWNERSHIP: VRFConsumerBaseV2Plus provides `ConfirmedOwner`, defaulting the owner to
///      whichever address calls the constructor (the deployer). This script proposes a transfer
///      to the configured Arbitrum-side governance address immediately via `transferOwnership`;
///      ConfirmedOwner's two-step design means the deployer's nominal ownership only ends once
///      that address itself calls `acceptOwnership()` (see the logged instructions below) --
///      intentional, so a transfer to a misconfigured or unreachable address can never
///      permanently strand the contract. In practice, arbitrumGovernance should be either the
///      same Safe (Safe supports deploying to the same address across chains via CREATE2, an
///      operational/deployment-tooling detail, not something this script manages) or a second
///      TimelockController deployed on Arbitrum One with that Safe as proposer, mirroring the
///      Robinhood Chain setup.
///
/// @dev SUBSCRIPTION MANAGEMENT: creating and funding the Chainlink VRF subscription, and adding
///      this wrapper as a consumer of it, are standard VRF operational steps performed via
///      Chainlink's own tooling (the VRF subscription manager UI, or `vrf-v2.5-sh` scripts) --
///      not reimplemented here. This script expects an already-created, already-funded
///      subscription ID as config.
contract DeployArbitrumWrapper is Script {
    function run() external returns (VRFWrapperOnArbitrum wrapper) {
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR_ARBITRUM");
        address ccipRouter = vm.envAddress("CCIP_ROUTER_ARBITRUM");
        uint64 robinhoodChainSelector = uint64(vm.envUint("ROBINHOOD_CHAIN_SELECTOR"));
        bytes32 keyHash = vm.envBytes32("VRF_KEY_HASH");
        uint256 subscriptionId = vm.envUint("VRF_SUBSCRIPTION_ID");
        address arbitrumGovernance = vm.envAddress("ARBITRUM_GOVERNANCE_ADDRESS");

        vm.startBroadcast();

        wrapper = new VRFWrapperOnArbitrum(vrfCoordinator, ccipRouter, robinhoodChainSelector, keyHash, subscriptionId);
        // ConfirmedOwner uses a two-step transfer: this only PROPOSES the new owner. The deployer
        // retains nominal ownership until arbitrumGovernance itself calls acceptOwnership() --
        // by design, so a transfer to an unreachable/misconfigured address can never permanently
        // strand the contract. See the logged next step below.
        wrapper.transferOwnership(arbitrumGovernance);

        vm.stopBroadcast();

        console2.log("=== Arbitrum One Deployment Summary ===");
        console2.log("VRFWrapperOnArbitrum:", address(wrapper));
        console2.log("Ownership PROPOSED to:", arbitrumGovernance);
        console2.log("REQUIRED: arbitrumGovernance must call wrapper.acceptOwnership() to complete the transfer --");
        console2.log("until then, the deployer still nominally holds ownership (ConfirmedOwner's two-step design).");
        console2.log("NEXT STEPS (after acceptOwnership):");
        console2.log("1) wrapper.setProvider(providerOnRobinhoodChain) -- provider address from DeployRobinhoodChain.s.sol");
        console2.log("2) Register this wrapper as a consumer on VRF subscription:", subscriptionId);
        console2.log("   (via Chainlink's VRF subscription manager, or vrfCoordinator.addConsumer directly)");
        console2.log("Then run WireCrossChain.s.sol to complete provider.setWrapper(...) on the Robinhood Chain side.");
    }
}
