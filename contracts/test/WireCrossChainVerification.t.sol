// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkRandomnessProvider} from "../src/ChainlinkRandomnessProvider.sol";
import {VRFWrapperOnArbitrum} from "../src/VRFWrapperOnArbitrum.sol";
import {WireCrossChain} from "../script/WireCrossChain.s.sol";
import {MockCCIPRouter} from "@chainlink/contracts-ccip/contracts/test/mocks/MockRouter.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

/// @notice Verifies WireCrossChain.s.sol's chain-aware detection logic. In the real deployment,
///         `ChainlinkRandomnessProvider` exists ONLY on Robinhood Chain and `VRFWrapperOnArbitrum`
///         exists ONLY on Arbitrum One -- the two addresses can never both have real bytecode on
///         the same chain. Each test below simulates running the script "as if" pointed at one
///         real chain at a time: the contract that would actually live there is deployed for real,
///         and the other side's address is simply a value with no code at all here (exactly what
///         querying a remote-chain-only address's bytecode on the wrong chain actually looks
///         like) -- never both deployed into one EVM, which is the setup that originally masked
///         this bug.
contract WireCrossChainVerificationTest is Test {
    function _deployProvider() internal returns (ChainlinkRandomnessProvider) {
        MockCCIPRouter router = new MockCCIPRouter();
        return new ChainlinkRandomnessProvider(address(router), 12345, address(0x60401), address(this));
    }

    function _deployWrapper() internal returns (VRFWrapperOnArbitrum) {
        MockCCIPRouter router = new MockCCIPRouter();
        VRFCoordinatorV2_5Mock vrfCoordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 1e15);
        uint256 subId = vrfCoordinator.createSubscription();
        return new VRFWrapperOnArbitrum(address(vrfCoordinator), address(router), 54321, keccak256("test"), subId);
    }

    /// @notice Simulates running the script pointed at Robinhood Chain: only the provider has real
    ///         local bytecode here. The script must detect this correctly and log ONLY
    ///         provider.setWrapper's calldata -- and must not revert just because the wrapper
    ///         address (a value that only has code on a different chain) has none here.
    function test_wireCrossChain_detectsRobinhoodChain_whenOnlyProviderHasLocalCode() public {
        ChainlinkRandomnessProvider provider = _deployProvider();
        address remoteWrapperAddr = address(0xBEEF); // no code on THIS chain -- simulates Arbitrum One's address

        vm.setEnv("CHAINLINK_RANDOMNESS_PROVIDER", vm.toString(address(provider)));
        vm.setEnv("VRF_WRAPPER_ON_ARBITRUM", vm.toString(remoteWrapperAddr));

        WireCrossChain wireScript = new WireCrossChain();
        wireScript.run(); // must not revert
    }

    /// @notice Simulates running the script pointed at Arbitrum One: only the wrapper has real
    ///         local bytecode here. The script must detect this correctly and log ONLY
    ///         wrapper.setProvider's calldata -- the mirror image of the test above.
    function test_wireCrossChain_detectsArbitrumOne_whenOnlyWrapperHasLocalCode() public {
        VRFWrapperOnArbitrum wrapper = _deployWrapper();
        address remoteProviderAddr = address(0xCAFE); // no code on THIS chain -- simulates Robinhood Chain's address

        vm.setEnv("CHAINLINK_RANDOMNESS_PROVIDER", vm.toString(remoteProviderAddr));
        vm.setEnv("VRF_WRAPPER_ON_ARBITRUM", vm.toString(address(wrapper)));

        WireCrossChain wireScript = new WireCrossChain();
        wireScript.run(); // must not revert
    }

    /// @notice THE EXACT SCENARIO THAT ORIGINALLY MASKED THIS BUG: both real contracts deployed
    ///         into the same EVM. This can never legitimately happen in the real two-chain
    ///         deployment, so the fixed script must now explicitly reject it rather than silently
    ///         treat it as valid and log both governance actions as if either chain were correct.
    function test_wireCrossChain_revertsIfBothAddressesHaveLocalCode() public {
        ChainlinkRandomnessProvider provider = _deployProvider();
        VRFWrapperOnArbitrum wrapper = _deployWrapper();

        vm.setEnv("CHAINLINK_RANDOMNESS_PROVIDER", vm.toString(address(provider)));
        vm.setEnv("VRF_WRAPPER_ON_ARBITRUM", vm.toString(address(wrapper)));

        WireCrossChain wireScript = new WireCrossChain();
        vm.expectRevert(
            bytes(
                "WireCrossChain: both addresses have local bytecode -- provider and wrapper can never both live on the same chain in a real deployment; check --rpc-url"
            )
        );
        wireScript.run();
    }

    /// @notice Neither address resolving to real code almost always means the wrong --rpc-url, or
    ///         an address copied from a deployment that hasn't actually been broadcast yet -- the
    ///         script must fail loudly rather than silently produce output for a chain it can't
    ///         actually confirm anything on.
    function test_wireCrossChain_revertsIfNeitherAddressHasLocalCode() public {
        vm.setEnv("CHAINLINK_RANDOMNESS_PROVIDER", vm.toString(address(0x1111)));
        vm.setEnv("VRF_WRAPPER_ON_ARBITRUM", vm.toString(address(0x2222)));

        WireCrossChain wireScript = new WireCrossChain();
        vm.expectRevert(
            bytes(
                "WireCrossChain: neither address has local bytecode on this chain -- check --rpc-url and that both deployments have already been broadcast"
            )
        );
        wireScript.run();
    }
}
