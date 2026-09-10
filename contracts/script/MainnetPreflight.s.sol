// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IVRFSubscriptionV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFSubscriptionV2Plus.sol";

/// @title MainnetPreflight
/// @notice Read-only sanity checks before broadcasting anything for the CLOG mainnet deployment.
///         Run once per chain (via --rpc-url) - detects which chain it's on from block.chainid and
///         runs the checks relevant to that side. Never broadcasts, never sends a transaction - every
///         function called here is either a view/pure read or a Foundry cheatcode.
///
/// @dev Robinhood Chain checks: CCIP router bytecode, router supports the Arbitrum selector, a
///      representative getFee() quote (the exact message shape ChainlinkRandomnessProvider actually
///      sends), SAFE_ADDRESS bytecode if supplied, deployer ETH balance if supplied.
/// @dev Arbitrum One checks: CCIP router bytecode, VRF Coordinator bytecode, router supports the
///      Robinhood selector, a representative getFee() quote for the return leg,
///      ARBITRUM_GOVERNANCE_ADDRESS bytecode if supplied, deployer ETH balance if supplied, and VRF
///      subscription existence/config via the coordinator's own getSubscription() if
///      VRF_SUBSCRIPTION_ID is supplied.
///
/// Env vars read (all optional except the router/coordinator addresses for whichever chain you're
/// actually pointed at - see the require()s below for which ones are mandatory per chain):
///   CCIP_ROUTER_ROBINHOOD, ARBITRUM_CHAIN_SELECTOR, SAFE_ADDRESS, DEPLOYER_ADDRESS
///   CCIP_ROUTER_ARBITRUM, ROBINHOOD_CHAIN_SELECTOR, VRF_COORDINATOR_ARBITRUM,
///   ARBITRUM_GOVERNANCE_ADDRESS, VRF_SUBSCRIPTION_ID
contract MainnetPreflight is Script {
    uint256 constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 constant ARBITRUM_CHAIN_ID = 42161;

    function run() external view {
        if (block.chainid == ROBINHOOD_CHAIN_ID) {
            _runRobinhoodChecks();
        } else if (block.chainid == ARBITRUM_CHAIN_ID) {
            _runArbitrumChecks();
        } else {
            revert("MainnetPreflight: unrecognized chain id - check --rpc-url points at Robinhood Chain Mainnet (4663) or Arbitrum One (42161)");
        }
    }

    function _runRobinhoodChecks() internal view {
        console2.log("=== ROBINHOOD CHAIN MAINNET PREFLIGHT ===");
        console2.log("chain id:", block.chainid);

        address router = vm.envAddress("CCIP_ROUTER_ROBINHOOD");
        uint64 arbitrumSelector = uint64(vm.envUint("ARBITRUM_CHAIN_SELECTOR"));

        console2.log("Robinhood CCIP Router:", router);
        console2.log("  bytecode length:", router.code.length);
        require(router.code.length > 0, "FAIL: no bytecode at CCIP_ROUTER_ROBINHOOD");

        bool supported = IRouterClient(router).isChainSupported(arbitrumSelector);
        console2.log("  isChainSupported(Arbitrum selector):", supported);
        require(supported, "FAIL: Robinhood router does not report the Arbitrum selector as supported");

        // Representative getFee() - the exact message shape
        // ChainlinkRandomnessProvider.requestRandomness actually builds (see its own source), so
        // this is a real quote for the real message this system will actually send, not a guess.
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(address(0xdEaD)), // placeholder destination - fee depends on message shape, not the specific address
            data: abi.encode(uint256(1), uint256(1)), // representative payload size: (requestId, roundId)
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 300_000, allowOutOfOrderExecution: true}))
        });
        try IRouterClient(router).getFee(arbitrumSelector, message) returns (uint256 fee) {
            console2.log("  representative getFee() (wei):", fee);
        } catch {
            console2.log("  getFee() reverted - investigate before relying on this router/selector pair");
        }

        address safe = vm.envOr("SAFE_ADDRESS", address(0));
        if (safe != address(0)) {
            console2.log("SAFE_ADDRESS:", safe);
            console2.log("  bytecode length:", safe.code.length);
            require(safe.code.length > 0, "FAIL: SAFE_ADDRESS has no code on Robinhood Chain");
        } else {
            console2.log("SAFE_ADDRESS not supplied - skipped");
        }

        address deployer = vm.envOr("DEPLOYER_ADDRESS", address(0));
        if (deployer != address(0)) {
            console2.log("Deployer address:", deployer);
            console2.log("  ETH balance (wei):", deployer.balance);
            require(deployer.balance > 0, "FAIL: deployer has zero ETH balance on Robinhood Chain");
        } else {
            console2.log("DEPLOYER_ADDRESS not supplied - skipped");
        }

        console2.log("=== Robinhood checks complete ===");
    }

    function _runArbitrumChecks() internal view {
        console2.log("=== ARBITRUM ONE PREFLIGHT ===");
        console2.log("chain id:", block.chainid);

        address router = vm.envAddress("CCIP_ROUTER_ARBITRUM");
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR_ARBITRUM");
        uint64 robinhoodSelector = uint64(vm.envUint("ROBINHOOD_CHAIN_SELECTOR"));

        console2.log("Arbitrum CCIP Router:", router);
        console2.log("  bytecode length:", router.code.length);
        require(router.code.length > 0, "FAIL: no bytecode at CCIP_ROUTER_ARBITRUM");

        console2.log("VRF Coordinator:", vrfCoordinator);
        console2.log("  bytecode length:", vrfCoordinator.code.length);
        require(vrfCoordinator.code.length > 0, "FAIL: no bytecode at VRF_COORDINATOR_ARBITRUM");

        bool supported = IRouterClient(router).isChainSupported(robinhoodSelector);
        console2.log("  isChainSupported(Robinhood selector):", supported);
        require(supported, "FAIL: Arbitrum router does not report the Robinhood selector as supported");

        // Representative getFee() for the RETURN leg - the exact shape
        // VRFWrapperOnArbitrum.relayRandomness actually builds.
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(address(0xdEaD)),
            data: abi.encode(uint256(1), uint256(1)), // representative payload: (originalRequestId, randomWord)
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 300_000, allowOutOfOrderExecution: true}))
        });
        try IRouterClient(router).getFee(robinhoodSelector, message) returns (uint256 fee) {
            console2.log("  representative getFee() (wei):", fee);
        } catch {
            console2.log("  getFee() reverted - investigate before relying on this router/selector pair");
        }

        address arbitrumGovernance = vm.envOr("ARBITRUM_GOVERNANCE_ADDRESS", address(0));
        if (arbitrumGovernance != address(0)) {
            console2.log("ARBITRUM_GOVERNANCE_ADDRESS:", arbitrumGovernance);
            console2.log("  bytecode length:", arbitrumGovernance.code.length);
            if (arbitrumGovernance.code.length == 0) {
                console2.log("  NOTE: no code here - only a problem if this is meant to be a Safe/contract; fine if it's a plain EOA");
            }
        } else {
            console2.log("ARBITRUM_GOVERNANCE_ADDRESS not supplied - skipped");
        }

        address deployer = vm.envOr("DEPLOYER_ADDRESS", address(0));
        if (deployer != address(0)) {
            console2.log("Deployer address:", deployer);
            console2.log("  ETH balance (wei):", deployer.balance);
            require(deployer.balance > 0, "FAIL: deployer has zero ETH balance on Arbitrum One");
        } else {
            console2.log("DEPLOYER_ADDRESS not supplied - skipped");
        }

        uint256 subId = vm.envOr("VRF_SUBSCRIPTION_ID", uint256(0));
        if (subId != 0) {
            console2.log("VRF_SUBSCRIPTION_ID:", subId);
            try IVRFSubscriptionV2Plus(vrfCoordinator).getSubscription(subId) returns (
                uint96 balance, uint96 nativeBalance, uint64 reqCount, address owner, address[] memory consumers
            ) {
                console2.log("  subscription exists, owner:", owner);
                console2.log("  LINK balance:", balance);
                console2.log("  native balance:", nativeBalance);
                console2.log("  request count:", reqCount);
                console2.log("  current consumer count:", consumers.length);
                require(owner != address(0), "FAIL: subscription reports a zero owner - it may not actually exist");
            } catch {
                revert("FAIL: getSubscription() reverted - this subscription ID likely does not exist on this coordinator");
            }
        } else {
            console2.log("VRF_SUBSCRIPTION_ID not supplied yet - skipped (expected before you've created it)");
        }

        console2.log("=== Arbitrum checks complete ===");
    }
}
