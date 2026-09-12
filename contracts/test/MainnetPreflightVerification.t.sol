// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MainnetPreflight} from "../script/MainnetPreflight.s.sol";
import {MockCCIPRouter} from "@chainlink/contracts-ccip/contracts/test/mocks/MockRouter.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {ChainlinkRandomnessProvider} from "../src/ChainlinkRandomnessProvider.sol";

/// @notice Captures the exact `data` bytes passed to getFee(), so a test can directly compare
///         what MainnetPreflight's own "representative" quote message sends against what the
///         real ChainlinkRandomnessProvider/VRFWrapperOnArbitrum actually send - the only way to
///         provably catch the two silently diverging again, rather than merely re-asserting a
///         hardcoded expectation that could itself drift from the real contracts unnoticed.
contract CapturingCCIPRouter is IRouterClient {
    bytes public lastCapturedData;
    uint256 public callCount;

    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external pure returns (uint256) {
        // Cannot capture here: IRouterClient declares getFee `view`, so Solidity enforces this
        // override cannot be less restrictive (confirmed directly: compiling a non-view override
        // is a hard error, "Overriding function changes state mutability from view to
        // nonpayable") - the real EVM-level STATICCALL this produces would reject any state
        // write attempted inside anyway. Capture happens in ccipSend below instead, which carries
        // no such restriction and is what requestRandomness's real, actual send goes through.
        return 1;
    }

    function ccipSend(uint64, Client.EVM2AnyMessage calldata message) external payable returns (bytes32) {
        lastCapturedData = message.data;
        callCount++;
        return keccak256(message.data);
    }
}

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
/// @notice Proves ChainlinkRandomnessProvider.requestRandomness() really sends
///         `data: abi.encode(requestId)` (a single uint256) - captured via ccipSend (not getFee,
///         which IRouterClient declares `view`, forcing a STATICCALL that would reject any state
///         write a capturing mock's getFee() attempted) - and that MainnetPreflight.s.sol's own
///         Robinhood-side representative quote uses the identical shape, via a direct source-text
///         assertion. Together these two checks are what actually prevent the two from silently
///         diverging again: this test alone would not have caught the original bug (the quote
///         used a two-value payload while the real message is single-value) without both halves.
contract MainnetPreflightMessageShapeTest is Test {
    function test_requestRandomness_reallySendsASingleUint256_notAPair() public {
        CapturingCCIPRouter capturingRouter = new CapturingCCIPRouter();
        ChainlinkRandomnessProvider provider = new ChainlinkRandomnessProvider(
            address(capturingRouter), uint64(4949039107694359620), makeAddr("governance"), address(this)
        );
        // The test contract itself is round manager - onlyRoundManager then accepts calls made
        // directly from here, with no prank needed.
        provider.setRoundManager(address(this));
        vm.deal(address(provider), 10 ether);
        vm.prank(makeAddr("governance"));
        provider.setWrapper(makeAddr("wrapperPlaceholder"));

        provider.requestRandomness(1);

        assertEq(capturingRouter.callCount(), 1, "ccipSend must have been called exactly once");
        assertEq(
            capturingRouter.lastCapturedData(),
            abi.encode(uint256(1)),
            "requestRandomness must send exactly abi.encode(requestId) - a single uint256, never a pair"
        );
    }

    function test_mainnetPreflight_robinhoodQuote_usesTheSameSingleUint256Shape() public {
        string memory source = vm.readFile("script/MainnetPreflight.s.sol");
        assertTrue(
            _contains(source, "data: abi.encode(uint256(1)),"),
            "MainnetPreflight's Robinhood-side representative quote must use abi.encode(uint256(1)) - a single value, matching requestRandomness's real data: abi.encode(requestId)"
        );
        // The return-leg (Arbitrum -> Robinhood) quote is correctly a PAIR
        // (originalRequestId, randomWord) - matching relayRandomness's own real message shape -
        // and must stay that way; asserted here so a future edit that "fixes" this one too
        // (mistakenly matching it to the outbound shape) is itself caught.
        assertTrue(
            _contains(
                source,
                "data: abi.encode(uint256(1), uint256(1)), // representative payload: (originalRequestId, randomWord)"
            ),
            "MainnetPreflight's Arbitrum-side (return leg) representative quote must remain a pair - matching relayRandomness's real data: abi.encode(originalRequestId, randomWord)"
        );
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool matchFound = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    matchFound = false;
                    break;
                }
            }
            if (matchFound) return true;
        }
        return false;
    }
}

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

        vm.expectRevert(
            bytes("FAIL: getSubscription() reverted - this subscription ID likely does not exist on this coordinator")
        );
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
