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

/// @notice Verifies the final governance topology: the Safe is treasury/fee-recipient ONLY (no
///         timelock role whatsoever); the sole PROPOSER_ROLE and CANCELLER_ROLE belong to an
///         explicit, required GOVERNANCE_PROPOSER_ADDRESS env var, never inferred from
///         msg.sender/Foundry broadcast behavior; the executor stays open; the timelock still
///         self-administers; and none of this depends on which nonzero delay is configured.
contract DeployRobinhoodChainTimelockTest is Test {
    // Foundry's well-known default broadcast sender, used when vm.startBroadcast() is called
    // with no explicit address - observed directly via a full trace (forge test -vvvv), not
    // assumed.
    address constant DEFAULT_BROADCAST_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    address safe = makeAddr("safe");
    address governanceProposer = makeAddr("governanceProposer");
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
        // The Safe is used as both SAFE_ADDRESS and FEE_MULTISIG_ADDRESS - the script's own
        // _verify() now requires these to be the same address (Safe = fee recipient only).
        vm.setEnv("SAFE_ADDRESS", vm.toString(safe));
        vm.setEnv("FEE_MULTISIG_ADDRESS", vm.toString(safe));
        vm.setEnv("GOVERNANCE_PROPOSER_ADDRESS", vm.toString(governanceProposer));
        vm.setEnv("TICKER_NFT_BASE_URI", "https://clog.run/api/ticker-metadata/");
        // Production-scale threshold values (unrelated to what this file tests - timelock
        // governance topology, not economic thresholds) - matches what were previously hardcoded
        // constants on EligibilityRegistry/RoundManager, now required deployment-time config.
        vm.setEnv("MIN_PROGRESS_BPS", "500");
        vm.setEnv("MIN_RESERVE_THRESHOLD_WEI", "229000000000000000");
        vm.setEnv("REQUIRED_ABSOLUTE_SECONDS", "1800");
        vm.setEnv("ROUND_DURATION_SECONDS", "3600");
    }

    function test_missingGovernanceProposerEnvVar_revertsLoudly_notSilentDefault() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        // Explicitly overwritten to an empty (unparseable) value rather than left merely unset:
        // vm.setEnv() has no corresponding "unset" cheatcode in this forge-std version, and env
        // vars set via vm.setEnv() are process-level state that persists across every test
        // function in this suite - relying on "no earlier test happened to set this" would be
        // order-dependent and unreliable. An empty string still forces vm.envAddress's own
        // parse-failure revert (verified directly: vm.envAddress reverts with a parser error on
        // an empty string, the same as it does when the variable was genuinely never set),
        // regardless of what any other test already set this to.
        vm.setEnv("GOVERNANCE_PROPOSER_ADDRESS", "");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        vm.expectRevert();
        runCaller.callRun(deployer);
    }

    function test_missingTimelockDelayEnvVar_revertsLoudly_notSilentDefault() public {
        _setCommonEnv();
        // Same reasoning as above - explicitly forced to an unparseable value rather than
        // relying on this variable having never been set by an earlier test in this suite.
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        vm.expectRevert();
        runCaller.callRun(deployer);
    }

    // 1. zero-delay deployment gives getMinDelay() == 0
    function test_zeroDelay_timelockDeploysWithZeroMinDelay() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        assertEq(d.timelock.getMinDelay(), 0, "min delay must be exactly 0");
    }

    // 2 & 3. deployer/operator address has PROPOSER_ROLE and CANCELLER_ROLE
    function test_governanceProposer_holdsProposerAndCancellerRole() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        assertTrue(
            d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), governanceProposer),
            "governance proposer must hold proposer role"
        );
        assertTrue(
            d.timelock.hasRole(d.timelock.CANCELLER_ROLE(), governanceProposer),
            "governance proposer must hold canceller role"
        );
    }

    // 4. Safe has neither proposer nor canceller role
    function test_safe_holdsNoProposerOrCancellerRole() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        assertFalse(d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), safe), "Safe must NOT hold proposer role");
        assertFalse(d.timelock.hasRole(d.timelock.CANCELLER_ROLE(), safe), "Safe must NOT hold canceller role");
    }

    // 5. neither deployer nor Safe has DEFAULT_ADMIN_ROLE
    function test_neitherGovernanceProposerNorSafe_holdsAdminRole() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        assertFalse(
            d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), governanceProposer),
            "governance proposer must not hold admin role"
        );
        assertFalse(d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), safe), "Safe must not hold admin role");
    }

    // 6. open executor remains configured
    function test_openExecutor_remainsConfigured() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        // "Granting a role to address(0) is equivalent to enabling this role for everyone" -
        // TimelockController's own onlyRoleOrOpenRole doc comment, confirmed directly in the
        // vendored source rather than assumed.
        assertTrue(d.timelock.hasRole(d.timelock.EXECUTOR_ROLE(), address(0)), "executor must remain open");
    }

    // 7. a governed action can be scheduled by the deployer and executed immediately with zero
    //    elapsed time
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
        vm.prank(governanceProposer);
        d.timelock.schedule(address(d.roundManager), 0, callData, bytes32(0), salt, configuredDelay);

        // The critical proof: execute in the SAME block, with zero time elapsed - no vm.warp()
        // (beyond setUp's own one-time warp) anywhere in this test. If the configured delay
        // were anything other than genuinely zero, this execute() call would revert with
        // TimelockUnexpectedOperationState.
        d.timelock.execute(address(d.roundManager), 0, callData, bytes32(0), salt);

        assertEq(address(d.roundManager.rewardVault()), address(d.rewardVault), "action must have actually executed");
    }

    // 7 (negative control). the Safe cannot schedule anything - it holds no proposer role
    function test_safe_cannotScheduleAnAction() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        bytes memory callData = abi.encodeCall(RoundManager.setRewardVault, (address(d.rewardVault)));
        uint256 configuredDelay = d.timelock.getMinDelay();

        vm.prank(safe);
        vm.expectRevert();
        d.timelock.schedule(address(d.roundManager), 0, callData, bytes32(0), bytes32(uint256(99)), configuredDelay);
    }

    // 8. the Safe remains the fee recipient passed to TickerRegistry
    function test_safe_remainsTheFeeRecipientOnTickerRegistry() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        assertEq(d.tickerRegistry.multisig(), safe, "Safe must remain the fee recipient wired into TickerRegistry");
    }

    // 9. RoundManager, randomness provider and TickerRegistry governance still point to the
    //    Timelock
    function test_zeroDelay_governanceIsTheTimelockAddress_everywhere() public {
        _setCommonEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        DeployRobinhoodChain deployer = new DeployRobinhoodChain();
        DeployRobinhoodChain.Deployment memory d = runCaller.callRun(deployer);

        assertEq(d.roundManager.governance(), address(d.timelock), "RoundManager governance must be the timelock");
        assertEq(d.randomnessProvider.governance(), address(d.timelock), "provider governance must be the timelock");
        assertEq(d.tickerRegistry.governance(), address(d.timelock), "TickerRegistry governance must be the timelock");
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
        vm.prank(governanceProposer);
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
