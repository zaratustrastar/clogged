// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployRobinhoodChain} from "../script/DeployRobinhoodChain.s.sol";
import {RoundManager} from "../src/RoundManager.sol";

/// @notice run() reads msg.sender BEFORE vm.startBroadcast() takes effect (e.g.
///         `new EligibilityRegistry(msg.sender)` inside DeployRobinhoodChain.run() reflects
///         whoever called run(), an ordinary Solidity call-frame fact vm.startBroadcast() cannot
///         retroactively change) - but every OUTGOING call the script itself makes AFTER
///         vm.startBroadcast() (e.g. EligibilityRegistry.setRoundManager(...), called BY the
///         script) is intercepted to appear from Foundry's default broadcast sender instead.
///         Calling run() directly from an ordinary test function makes these two values diverge
///         (the test contract's own address vs. the default broadcast sender), which trips the
///         script's own "not deployer" one-time-setter guards - a test-harness artifact of
///         invoking a broadcasting script this way, not a bug in the script. vm.prank() cannot
///         fix this either: it is explicitly incompatible with vm.startBroadcast(). The fix is to
///         make the actual CALLER of run() be the exact address vm.startBroadcast() will later
///         use, via vm.etch()-ing a trivial forwarding contract onto that specific address.
contract RunCaller {
    function callRun(DeployRobinhoodChain deployer) external returns (DeployRobinhoodChain.Deployment memory) {
        return deployer.run();
    }
}

contract DeployRobinhoodChainTimelockTest is Test {
    // Foundry's well-known default broadcast sender, used when vm.startBroadcast() is called
    // with no explicit address - observed directly via a full trace (forge test -vvvv), not
    // assumed.
    address constant DEFAULT_BROADCAST_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    address safe = makeAddr("safe");
    address multisig = makeAddr("feeMultisig");
    address ccipRouter = makeAddr("ccipRouter");
    RunCaller runCaller;

    function setUp() public {
        // Deploy the forwarder normally to get its real bytecode, then place that exact bytecode
        // at DEFAULT_BROADCAST_SENDER so calls made THROUGH it originate from that address.
        RunCaller impl = new RunCaller();
        vm.etch(DEFAULT_BROADCAST_SENDER, address(impl).code);
        runCaller = RunCaller(DEFAULT_BROADCAST_SENDER);

        // Foundry's fresh test environment starts at block.timestamp == 1, which collides with
        // OpenZeppelin TimelockController's own _DONE_TIMESTAMP sentinel (also 1, verified
        // directly in the vendored source): a zero-delay operation scheduled at exactly
        // timestamp 1 gets a "ready at" timestamp of 1 + 0 = 1, which getOperationState()
        // checks against _DONE_TIMESTAMP BEFORE checking readiness - so it reads back as
        // already "Done" rather than "Ready", even though it was just scheduled. This is a real
        // edge case in OZ's own code, irrelevant on any real chain (real timestamps are never
        // 1), and only reachable in a fresh test environment - warping to a realistic timestamp
        // avoids it, matching what every real deployment's block.timestamp actually looks like.
        vm.warp(1_700_000_000);
    }

    function _setCommonEnv() internal {
        vm.setEnv("CCIP_ROUTER_ROBINHOOD", vm.toString(ccipRouter));
        vm.setEnv("ARBITRUM_CHAIN_SELECTOR", vm.toString(uint256(4949039107694359620)));
        vm.setEnv("SAFE_ADDRESS", vm.toString(safe));
        vm.setEnv("FEE_MULTISIG_ADDRESS", vm.toString(multisig));
        vm.setEnv("TICKER_NFT_BASE_URI", "https://clog.run/api/ticker-metadata/");
    }

    function test_missingTimelockDelayEnvVar_revertsLoudly_notSilentDefault() public {
        _setCommonEnv();
        // TIMELOCK_DELAY_SECONDS deliberately not set.
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        vm.expectRevert();
        runCaller.callRun(deployer);
    }

    function test_zeroDelay_timelockDeploysWithZeroMinDelay() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        assertEq(d.timelock.getMinDelay(), 0, "min delay must be exactly 0");
    }

    function test_zeroDelay_safeIsProposer() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        assertTrue(d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), safe), "Safe must hold proposer role");
    }

    function test_zeroDelay_deployerIsNotProposerOrAdmin() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        // DEFAULT_BROADCAST_SENDER is the real deployer here - the exact address the script's
        // own outgoing calls (and thus its constructor arguments) actually resolve to - and the
        // one that must hold no governance privilege.
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        assertFalse(
            d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), DEFAULT_BROADCAST_SENDER), "deployer must not be proposer"
        );
        assertFalse(
            d.timelock.hasRole(d.timelock.EXECUTOR_ROLE(), DEFAULT_BROADCAST_SENDER), "deployer must not be executor"
        );
        assertFalse(
            d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), DEFAULT_BROADCAST_SENDER), "deployer must not be admin"
        );
        // Nobody holds admin - the timelock self-administers, not even the Safe.
        assertFalse(d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), safe), "even the Safe must not be admin");
    }

    function test_zeroDelay_governanceIsTheTimelockAddress_everywhere() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        assertEq(d.roundManager.governance(), address(d.timelock), "RoundManager governance must be the timelock");
        assertEq(d.randomnessProvider.governance(), address(d.timelock), "provider governance must be the timelock");
        assertEq(d.tickerRegistry.governance(), address(d.timelock), "TickerRegistry governance must be the timelock");
    }

    function test_zeroDelay_scheduledActionExecutesImmediately_noWaitRequired() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        bytes memory callData = abi.encodeCall(RoundManager.setRewardVault, (address(d.rewardVault)));
        bytes32 salt = bytes32(uint256(1));

        // getMinDelay() read BEFORE the prank, not inline as a schedule() argument -
        // vm.prank() affects only the single next call, and evaluating
        // d.timelock.getMinDelay() as part of building schedule()'s own argument list
        // would itself be that next call, consuming the prank before schedule() ever runs.
        uint256 configuredDelay = d.timelock.getMinDelay();
        vm.prank(safe);
        d.timelock.schedule(address(d.roundManager), 0, callData, bytes32(0), salt, configuredDelay);

        // The critical proof: execute in the SAME block, with zero time elapsed - no vm.warp()
        // anywhere in this test. If the configured delay were anything other than genuinely zero,
        // this execute() call would revert with TimelockUnexpectedOperationState.
        d.timelock.execute(address(d.roundManager), 0, callData, bytes32(0), salt);

        assertEq(address(d.roundManager.rewardVault()), address(d.rewardVault), "action must have actually executed");
    }

    function test_nonzeroDelay_stillEnforcesTheConfiguredWait() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", vm.toString(uint256(2 days)));
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        assertEq(d.timelock.getMinDelay(), 2 days, "min delay must match the configured nonzero value");

        bytes memory callData = abi.encodeCall(RoundManager.setRewardVault, (address(d.rewardVault)));
        bytes32 salt = bytes32(uint256(2));

        uint256 configuredDelay2 = d.timelock.getMinDelay();
        vm.prank(safe);
        d.timelock.schedule(address(d.roundManager), 0, callData, bytes32(0), salt, configuredDelay2);

        // Executing immediately must still fail for a genuinely nonzero delay.
        vm.expectRevert();
        d.timelock.execute(address(d.roundManager), 0, callData, bytes32(0), salt);

        // After the real delay elapses, it succeeds normally - proving this deployment's
        // zero-delay support didn't come at the cost of breaking a real, nonzero delay.
        vm.warp(block.timestamp + 2 days);
        d.timelock.execute(address(d.roundManager), 0, callData, bytes32(0), salt);
        assertEq(
            address(d.roundManager.rewardVault()), address(d.rewardVault), "action must execute after the real wait"
        );
    }
}
