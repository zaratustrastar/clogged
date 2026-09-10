// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MainnetPreflight} from "../script/MainnetPreflight.s.sol";
import {MockCCIPRouter} from "@chainlink/contracts-ccip/contracts/test/mocks/MockRouter.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/// @notice The mock CCIP router's isChainSupported() always returns true (a hardcoded stub, not a
///         real configurable check) - this stands in for a router that does NOT support a given
///         destination, which the official mock can't simulate.
contract UnsupportedSelectorRouter is IRouterClient {
    function isChainSupported(uint64) external pure returns (bool) {
        return false;
    }
    function getFee(uint64, Client.EVM2AnyMessage memory) external pure returns (uint256) {
        return 0;
    }
    function ccipSend(uint64, Client.EVM2AnyMessage calldata) external payable returns (bytes32) {
        revert("not implemented");
    }
}

/// @notice I have no real RPC access to Robinhood Chain Mainnet or Arbitrum One in this
///         environment - these tests verify MainnetPreflight's actual logic (chain detection,
///         env var reading, pass/fail branching) using vm.chainId() to simulate each chain's id
///         and real mock contracts at whatever address they naturally deploy to (env vars point at
///         the mocks, not the real operator-supplied addresses, since this is testing the SCRIPT's
///         logic, not the real operator config itself).
contract MainnetPreflightVerificationTest is Test {
    MainnetPreflight preflight;

    function setUp() public {
        preflight = new MainnetPreflight();
        // vm.setEnv persists across test functions within a run (it's
        // process-level, not reset per test the way EVM state is) - reset
        // every optional var each test might rely on being "not supplied"
        // to a safe default here, so no test's result depends on Foundry's
        // (unspecified) execution order relative to any other test in this
        // file. Individual tests still set whatever they specifically need.
        vm.setEnv("SAFE_ADDRESS", vm.toString(address(0)));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(address(0)));
        vm.setEnv("ARBITRUM_GOVERNANCE_ADDRESS", vm.toString(address(0)));
        vm.setEnv("VRF_SUBSCRIPTION_ID", vm.toString(uint256(0)));
    }

    function test_revertsOnUnrecognizedChainId() public {
        vm.chainId(1); // Ethereum mainnet - neither Robinhood nor Arbitrum
        vm.expectRevert();
        preflight.run();
    }

    function test_robinhood_happyPath_allChecksPass() public {
        vm.chainId(4663);
        MockCCIPRouter router = new MockCCIPRouter();
        address deployer = address(0xD00D);
        vm.deal(deployer, 1 ether);

        vm.setEnv("CCIP_ROUTER_ROBINHOOD", vm.toString(address(router)));
        vm.setEnv("ARBITRUM_CHAIN_SELECTOR", vm.toString(uint256(4949039107694359620)));
        vm.setEnv("SAFE_ADDRESS", vm.toString(address(router))); // any address with real code
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));

        preflight.run(); // must not revert
    }

    function test_robinhood_failsCleanlyIfRouterHasNoBytecode() public {
        vm.chainId(4663);
        vm.setEnv("CCIP_ROUTER_ROBINHOOD", vm.toString(address(0xBEEF))); // no code here
        vm.setEnv("ARBITRUM_CHAIN_SELECTOR", vm.toString(uint256(4949039107694359620)));

        vm.expectRevert(bytes("FAIL: no bytecode at CCIP_ROUTER_ROBINHOOD"));
        preflight.run();
    }

    function test_robinhood_failsCleanlyIfSelectorNotSupported() public {
        vm.chainId(4663);
        UnsupportedSelectorRouter router = new UnsupportedSelectorRouter();
        vm.setEnv("CCIP_ROUTER_ROBINHOOD", vm.toString(address(router)));
        vm.setEnv("ARBITRUM_CHAIN_SELECTOR", vm.toString(uint256(4949039107694359620)));

        vm.expectRevert(bytes("FAIL: Robinhood router does not report the Arbitrum selector as supported"));
        preflight.run();
    }

    function test_robinhood_failsCleanlyIfSafeAddressHasNoBytecode() public {
        vm.chainId(4663);
        MockCCIPRouter router = new MockCCIPRouter();
        vm.setEnv("CCIP_ROUTER_ROBINHOOD", vm.toString(address(router)));
        vm.setEnv("ARBITRUM_CHAIN_SELECTOR", vm.toString(uint256(4949039107694359620)));
        vm.setEnv("SAFE_ADDRESS", vm.toString(address(0xC0FFEE))); // EOA, no code

        vm.expectRevert(bytes("FAIL: SAFE_ADDRESS has no code on Robinhood Chain"));
        preflight.run();
    }

    function test_robinhood_failsCleanlyIfDeployerHasZeroBalance() public {
        vm.chainId(4663);
        MockCCIPRouter router = new MockCCIPRouter();
        vm.setEnv("CCIP_ROUTER_ROBINHOOD", vm.toString(address(router)));
        vm.setEnv("ARBITRUM_CHAIN_SELECTOR", vm.toString(uint256(4949039107694359620)));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(address(0xD00D))); // never funded

        vm.expectRevert(bytes("FAIL: deployer has zero ETH balance on Robinhood Chain"));
        preflight.run();
    }

    function test_arbitrum_happyPath_allChecksPass() public {
        vm.chainId(42161);
        MockCCIPRouter router = new MockCCIPRouter();
        VRFCoordinatorV2_5Mock vrfCoordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 1e15);
        uint256 subId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(subId, 10 ether);
        address deployer = address(0xD00D);
        vm.deal(deployer, 1 ether);

        vm.setEnv("CCIP_ROUTER_ARBITRUM", vm.toString(address(router)));
        vm.setEnv("VRF_COORDINATOR_ARBITRUM", vm.toString(address(vrfCoordinator)));
        vm.setEnv("ROBINHOOD_CHAIN_SELECTOR", vm.toString(uint256(6180753054346818345)));
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));
        vm.setEnv("VRF_SUBSCRIPTION_ID", vm.toString(subId));

        preflight.run(); // must not revert
    }

    function test_arbitrum_failsCleanlyIfVrfCoordinatorHasNoBytecode() public {
        vm.chainId(42161);
        MockCCIPRouter router = new MockCCIPRouter();
        vm.setEnv("CCIP_ROUTER_ARBITRUM", vm.toString(address(router)));
        vm.setEnv("VRF_COORDINATOR_ARBITRUM", vm.toString(address(0xBEEF))); // no code
        vm.setEnv("ROBINHOOD_CHAIN_SELECTOR", vm.toString(uint256(6180753054346818345)));

        vm.expectRevert(bytes("FAIL: no bytecode at VRF_COORDINATOR_ARBITRUM"));
        preflight.run();
    }

    function test_arbitrum_failsCleanlyIfSubscriptionDoesNotExist() public {
        vm.chainId(42161);
        MockCCIPRouter router = new MockCCIPRouter();
        VRFCoordinatorV2_5Mock vrfCoordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 1e15);

        vm.setEnv("CCIP_ROUTER_ARBITRUM", vm.toString(address(router)));
        vm.setEnv("VRF_COORDINATOR_ARBITRUM", vm.toString(address(vrfCoordinator)));
        vm.setEnv("ROBINHOOD_CHAIN_SELECTOR", vm.toString(uint256(6180753054346818345)));
        vm.setEnv("VRF_SUBSCRIPTION_ID", vm.toString(uint256(999999))); // never created
        // Reset - vm.setEnv persists across test functions; without this, a
        // real, funded DEPLOYER_ADDRESS from an earlier test would leak in
        // unfunded on this test's fresh EVM state and revert at the
        // deployer-balance check instead, before ever reaching the
        // subscription check this test actually means to exercise.
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(address(0)));

        vm.expectRevert(bytes("FAIL: getSubscription() reverted - this subscription ID likely does not exist on this coordinator"));
        preflight.run();
    }

    function test_arbitrum_skipsSubscriptionCheckWhenNotYetSupplied() public {
        vm.chainId(42161);
        MockCCIPRouter router = new MockCCIPRouter();
        VRFCoordinatorV2_5Mock vrfCoordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 1e15);

        vm.setEnv("CCIP_ROUTER_ARBITRUM", vm.toString(address(router)));
        vm.setEnv("VRF_COORDINATOR_ARBITRUM", vm.toString(address(vrfCoordinator)));
        vm.setEnv("ROBINHOOD_CHAIN_SELECTOR", vm.toString(uint256(6180753054346818345)));
        vm.setEnv("VRF_SUBSCRIPTION_ID", vm.toString(uint256(0))); // explicitly not supplied
        // Foundry's vm.setEnv persists across test functions within the same
        // run (it's process-level, not reset per test like EVM state is) -
        // an earlier test in this file sets DEPLOYER_ADDRESS to a real,
        // funded address; without resetting it here too, this test would
        // silently inherit that leaked value and fail on an unrelated
        // assertion.
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(address(0)));

        preflight.run(); // must not revert - subscription check is skipped, not failed
    }
}
