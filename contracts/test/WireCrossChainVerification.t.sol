// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkRandomnessProvider} from "../src/ChainlinkRandomnessProvider.sol";
import {VRFWrapperOnArbitrum} from "../src/VRFWrapperOnArbitrum.sol";
import {WireCrossChain} from "../script/WireCrossChain.s.sol";
import {MockCCIPRouter} from "@chainlink/contracts-ccip/contracts/test/mocks/MockRouter.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

/// @notice Verifies WireCrossChain.s.sol's logic against REAL deployed contracts. This script
///         inherently depends on both sides already existing on-chain (its own sanity check reads
///         `code.length > 0`), which a standalone `forge script` dry run can't satisfy -- each
///         separate invocation runs against a fresh, empty EVM state. Deploying both sides for
///         real within a single test's EVM state is the correct way to exercise it, and doubles as
///         a permanent regression check that the script's calldata generation still matches
///         setWrapper/setProvider's actual current signatures if either ever changes.
contract WireCrossChainVerificationTest is Test {
    function test_wireCrossChain_runsCleanlyAgainstRealDeployedContracts() public {
        MockCCIPRouter router = new MockCCIPRouter();
        VRFCoordinatorV2_5Mock vrfCoordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 1e15);
        uint256 subId = vrfCoordinator.createSubscription();

        ChainlinkRandomnessProvider provider =
            new ChainlinkRandomnessProvider(address(router), 12345, address(0x60401), address(this));
        VRFWrapperOnArbitrum wrapper =
            new VRFWrapperOnArbitrum(address(vrfCoordinator), address(router), 54321, keccak256("test"), subId);

        vm.setEnv("CHAINLINK_RANDOMNESS_PROVIDER", vm.toString(address(provider)));
        vm.setEnv("VRF_WRAPPER_ON_ARBITRUM", vm.toString(address(wrapper)));

        WireCrossChain wireScript = new WireCrossChain();
        // Must not revert -- confirms both the code-length sanity check passes against real
        // contracts and the calldata-generation logic (abi.encodeCall against the actual current
        // setWrapper/setProvider signatures) compiles and runs cleanly.
        wireScript.run();
    }
}
