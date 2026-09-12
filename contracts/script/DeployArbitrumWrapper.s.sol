// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VRFWrapperOnArbitrum} from "../src/VRFWrapperOnArbitrum.sol";

/// @title DeployArbitrumWrapper
/// @notice Deploys VRFWrapperOnArbitrum on Arbitrum One and points its ownership at governance.
///         Despite the deployment order this repo happens to document elsewhere, this script
///         itself has NO ordering dependency on DeployRobinhoodChain.s.sol: the constructor below
///         takes only Arbitrum-side config (VRF coordinator, CCIP router, the Robinhood chain
///         selector, key hash, subscription id) - never the Robinhood-side
///         ChainlinkRandomnessProvider address, which is wired in separately afterward via
///         `wrapper.setProvider(...)` (see the logged next steps). Run this whenever convenient;
///         just call setProvider once the real provider address is known, and run
///         WireCrossChain.s.sol afterward to complete the Robinhood-side half of the wiring.
///
/// @dev OWNERSHIP: VRFConsumerBaseV2Plus provides `ConfirmedOwner`, defaulting the owner to
///      whichever address calls the constructor (the deployer). If the configured
///      ARBITRUM_GOVERNANCE_ADDRESS is a DIFFERENT address, this script proposes a transfer to it
///      immediately via `transferOwnership`; ConfirmedOwner's two-step design means the
///      deployer's nominal ownership only ends once that address itself calls
///      `acceptOwnership()` (see the logged instructions below) -- intentional, so a transfer to
///      a misconfigured or unreachable address can never permanently strand the contract. If
///      ARBITRUM_GOVERNANCE_ADDRESS is instead the SAME address that just deployed the wrapper
///      (i.e. it already equals `wrapper.owner()` immediately after construction - exactly the
///      canary's own configuration, where the deployer EOA is itself the final operational
///      governance for this wrapper), `transferOwnership` is skipped entirely: ConfirmedOwner's
///      own `_transferOwnership` has a hard `require(to != msg.sender, "Cannot transfer to
///      self")` (confirmed directly in the vendored source) that would otherwise revert the
///      whole deployment transaction. In practice, for a topology where governance is NOT the
///      deployer, arbitrumGovernance should be either the same Safe (Safe supports deploying to
///      the same address across chains via CREATE2, an operational/deployment-tooling detail,
///      not something this script manages) or a second TimelockController deployed on Arbitrum
///      One with that Safe as proposer, mirroring the Robinhood Chain setup.
///
/// @dev SUBSCRIPTION MANAGEMENT: creating and funding the Chainlink VRF subscription, and adding
///      this wrapper as a consumer of it, are standard VRF operational steps performed via
///      Chainlink's own tooling (the VRF subscription manager UI, or `vrf-v2.5-sh` scripts) --
///      not reimplemented here. This script expects an already-created, already-funded
///      subscription ID as config.
///
/// @dev CONSTRUCTOR DOES NOT NEED THE ROBINHOOD PROVIDER ADDRESS: VRFWrapperOnArbitrum's own
///      constructor takes only (vrfCoordinator, ccipRouter, robinhoodChainSelector, keyHash,
///      subscriptionId) - the Robinhood-side ChainlinkRandomnessProvider address is wired in
///      separately afterward via `wrapper.setProvider(...)`, a governance-gated setter, exactly
///      as logged in the next-steps output below. This script can therefore run before, after,
///      or independently of when DeployRobinhoodChain.s.sol runs - there is no ordering
///      dependency between the two beyond needing the real provider address in hand before
///      calling setProvider.
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

        // The deployer (whoever actually broadcasts this transaction) is the wrapper's owner
        // immediately after construction - read it back directly rather than assuming it equals
        // some locally-known "deployer" variable, so this comparison is correct regardless of
        // how the broadcast sender is configured.
        address ownerAfterConstruction = wrapper.owner();
        bool ownershipRetained = arbitrumGovernance == ownerAfterConstruction;

        if (!ownershipRetained) {
            // ConfirmedOwner uses a two-step transfer: this only PROPOSES the new owner. The
            // deployer retains nominal ownership until arbitrumGovernance itself calls
            // acceptOwnership() -- by design, so a transfer to an unreachable/misconfigured
            // address can never permanently strand the contract. See the logged next step below.
            wrapper.transferOwnership(arbitrumGovernance);
        }

        vm.stopBroadcast();

        console2.log("=== Arbitrum One Deployment Summary ===");
        console2.log("VRFWrapperOnArbitrum:", address(wrapper));
        if (ownershipRetained) {
            console2.log(
                "Ownership RETAINED: ARBITRUM_GOVERNANCE_ADDRESS already equals the deployer/owner",
                ownerAfterConstruction
            );
            console2.log("-- transferOwnership was correctly skipped (ConfirmedOwner rejects a transfer to self).");
            console2.log("No further ownership action needed.");
        } else {
            console2.log("Ownership PROPOSED to:", arbitrumGovernance);
            console2.log("REQUIRED: arbitrumGovernance must call wrapper.acceptOwnership() to complete the transfer --");
            console2.log("until then, the deployer still nominally holds ownership (ConfirmedOwner's two-step design).");
        }
        console2.log("NEXT STEPS:");
        console2.log(
            "1) wrapper.setProvider(providerOnRobinhoodChain) -- provider address from DeployRobinhoodChain.s.sol"
        );
        console2.log("2) Register this wrapper as a consumer on VRF subscription:", subscriptionId);
        console2.log("   (via Chainlink's VRF subscription manager, or vrfCoordinator.addConsumer directly)");
        console2.log("Then run WireCrossChain.s.sol to complete provider.setWrapper(...) on the Robinhood Chain side.");
        console2.log("");
        console2.log("=== Funding requirement (ongoing, not one-time) ===");
        console2.log("This wrapper must hold ETH to pay the return CCIP fee every time relayRandomness()");
        console2.log("sends a fulfilled word back to Robinhood Chain -- target:", address(wrapper));
        console2.log("If this balance runs out, the fulfilled random word is still stored safely (fulfillment");
        console2.log("and relay are fully decoupled) -- only the relay itself fails and becomes retryable via");
        console2.log("relayRandomness() once topped up. No specific amount is prescribed here -- it depends on");
        console2.log("live CCIP fee pricing at relay time, which this script has no way to know in advance;");
        console2.log("fund it, monitor it, and top it up as needed. Separately, remember the VRF subscription");
        console2.log("itself (subscriptionId above) needs its own LINK funding, managed via Chainlink's own");
        console2.log("tooling -- this wrapper's own ETH balance and the VRF subscription's LINK balance are");
        console2.log("two entirely separate funding requirements.");
    }
}
