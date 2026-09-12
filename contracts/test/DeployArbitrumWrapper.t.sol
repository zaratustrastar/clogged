// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployArbitrumWrapper} from "../script/DeployArbitrumWrapper.s.sol";
import {VRFWrapperOnArbitrum} from "../src/VRFWrapperOnArbitrum.sol";

/// @notice run() reads msg.sender BEFORE vm.startBroadcast() takes effect (an ordinary Solidity
///         call-frame fact vm.startBroadcast() cannot retroactively change - see the identical,
///         already-established note in DeployRobinhoodChainTimelock.t.sol), while every outgoing
///         call the script itself makes AFTER vm.startBroadcast() is intercepted to appear from
///         Foundry's default broadcast sender instead. Calling run() directly from an ordinary
///         test function makes these two values diverge; forwarding through a contract etched at
///         the exact default broadcast sender address makes the actual CALLER of run() be that
///         same address, resolving the mismatch.
contract RunCaller {
    function callRun(DeployArbitrumWrapper deployer) external returns (VRFWrapperOnArbitrum) {
        return deployer.run();
    }
}

contract DeployArbitrumWrapperTest is Test {
    address constant DEFAULT_BROADCAST_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    address vrfCoordinator = makeAddr("vrfCoordinator");
    address ccipRouter = makeAddr("ccipRouter");
    RunCaller runCaller;

    function setUp() public {
        RunCaller impl = new RunCaller();
        vm.etch(DEFAULT_BROADCAST_SENDER, address(impl).code);
        runCaller = RunCaller(DEFAULT_BROADCAST_SENDER);
    }

    function _setCommonEnv() internal {
        vm.setEnv("VRF_COORDINATOR_ARBITRUM", vm.toString(vrfCoordinator));
        vm.setEnv("CCIP_ROUTER_ARBITRUM", vm.toString(ccipRouter));
        vm.setEnv("ROBINHOOD_CHAIN_SELECTOR", vm.toString(uint256(6180753054346818345)));
        vm.setEnv("VRF_KEY_HASH", vm.toString(bytes32(uint256(0xdead))));
        vm.setEnv("VRF_SUBSCRIPTION_ID", "1");
    }

    /// @notice The canary's own real configuration: ARBITRUM_GOVERNANCE_ADDRESS is the same
    ///         deployer EOA that broadcasts this deployment. Before this fix, the script
    ///         unconditionally called transferOwnership(arbitrumGovernance), which reverts with
    ///         ConfirmedOwner's own "Cannot transfer to self" check whenever this is true -
    ///         confirmed directly against the vendored source, not assumed. This test is the
    ///         canary's own configuration reproduced exactly, so a regression here would have
    ///         reverted the real canary deployment.
    function test_sameGovernanceAsDeployer_doesNotRevert_andRetainsOwnership() public {
        _setCommonEnv();
        vm.setEnv("ARBITRUM_GOVERNANCE_ADDRESS", vm.toString(DEFAULT_BROADCAST_SENDER));

        DeployArbitrumWrapper deployer = new DeployArbitrumWrapper();
        VRFWrapperOnArbitrum wrapper = runCaller.callRun(deployer);

        assertEq(wrapper.owner(), DEFAULT_BROADCAST_SENDER, "the deployer must remain owner outright");

        // Confirm transferOwnership was genuinely never called (not just "happened to already be
        // correct"): acceptOwnership() from the governance address must revert, since there is no
        // pending transfer to accept (s_pendingOwner was never set to anything).
        vm.prank(DEFAULT_BROADCAST_SENDER);
        vm.expectRevert("Must be proposed owner");
        wrapper.acceptOwnership();
    }

    /// @notice The general case: governance is a genuinely different address. The existing
    ///         two-step transferOwnership/acceptOwnership behavior must be fully preserved.
    function test_differentGovernanceThanDeployer_proposesTransfer_twoStepPreserved() public {
        _setCommonEnv();
        address distinctGovernance = makeAddr("distinctGovernance");
        vm.setEnv("ARBITRUM_GOVERNANCE_ADDRESS", vm.toString(distinctGovernance));

        DeployArbitrumWrapper deployer = new DeployArbitrumWrapper();
        VRFWrapperOnArbitrum wrapper = runCaller.callRun(deployer);

        // Ownership transfer is only PROPOSED, not completed, immediately after the script runs -
        // the deployer still nominally holds it until acceptOwnership() is called.
        assertEq(
            wrapper.owner(), DEFAULT_BROADCAST_SENDER, "deployer must still nominally hold ownership pre-acceptance"
        );

        vm.prank(distinctGovernance);
        wrapper.acceptOwnership();
        assertEq(wrapper.owner(), distinctGovernance, "governance must hold ownership once it accepts");
    }
}
