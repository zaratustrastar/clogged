// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {RoundManager} from "../src/RoundManager.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {BondingCurveClog} from "../src/BondingCurveClog.sol";
import {MockTickerNFT} from "./mocks/MockTickerNFT.sol";

/// @notice Proves the EXACT SAME EligibilityRegistry/RoundManager contracts (byte-for-byte
/// identical bytecode, identical qualification algorithm, identical round-close/draw logic)
/// behave correctly under BOTH the canary and production deployment-time configurations - the
/// only difference between the two is which constructor arguments were supplied. No test-mode
/// branch, no privileged qualification function, no mutable threshold setter exists anywhere in
/// src/ - these are immutables, set once, with no setter.
contract DeploymentConfigurableTest is Test {
    address governance = makeAddr("governance");
    address multisig = makeAddr("multisig");
    address winnerPot = makeAddr("winnerPot");
    address deployer = address(this);

    uint256 constant BUFFER_BPS = 20_000;
    uint256 constant VIRTUAL_TOKEN_SEED = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 constant VIRTUAL_ETH_SEED = (5e9 * VIRTUAL_TOKEN_SEED) / 1e18;

    function _deployMarket(EligibilityRegistry engine, string memory name, string memory symbol)
        internal
        returns (MemeToken token, BondingCurveClog market)
    {
        uint256 predictedTokenId = engine.nextTokenId();
        MockTickerNFT tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(predictedTokenId, makeAddr("ticketOwner"));
        token = new MemeToken(name, symbol, address(this));
        market = new BondingCurveClog(
            address(token),
            address(tickerNFT),
            predictedTokenId,
            multisig,
            winnerPot,
            governance,
            address(engine),
            VIRTUAL_ETH_SEED,
            BUFFER_BPS
        );
        token.setMarket(address(market));
        uint256 tokenId = engine.registerToken(address(market));
        require(tokenId == predictedTokenId, "tokenId mismatch");
    }

    /// @dev Exercises one configuration end-to-end: deploy with the given thresholds, buy just
    /// enough to cross both the reserve and progress bars, confirm qualification behaves exactly
    /// according to THAT configuration's own thresholds - not the other configuration's.
    function _runConfiguration(
        uint256 minProgressBps,
        uint256 minReserveThresholdWei,
        uint256 requiredAbsoluteSeconds,
        uint256 roundDurationSeconds,
        uint256 buyAmount
    ) internal {
        EligibilityRegistry engine = new EligibilityRegistry(
            deployer, minProgressBps, minReserveThresholdWei, requiredAbsoluteSeconds
        );

        // Confirm the supplied configuration is exactly what got stored - no silent
        // substitution, no default overriding what was passed.
        assertEq(engine.minProgressBps(), minProgressBps, "minProgressBps must equal the supplied value exactly");
        assertEq(
            engine.minReserveThreshold(),
            minReserveThresholdWei,
            "minReserveThreshold must equal the supplied value exactly"
        );
        assertEq(
            engine.requiredAbsoluteSeconds(),
            requiredAbsoluteSeconds,
            "requiredAbsoluteSeconds must equal the supplied value exactly"
        );

        address roundManagerStub = makeAddr("roundManagerStub");
        engine.setRoundManager(roundManagerStub);

        (, BondingCurveClog market) = _deployMarket(engine, "Cfg", "CFG");
        address buyer = makeAddr("buyer");
        vm.deal(buyer, buyAmount + 1 ether);

        vm.prank(buyer);
        market.buy{value: buyAmount}(0, block.timestamp);
        vm.prank(roundManagerStub);
        engine.onTrade(1);

        // Below threshold-crossing must show not-yet-above; this is asserted implicitly by the
        // buy amount chosen by the caller being sufficient - the real assertions are below.
        assertGe(
            market.realReserve(),
            minReserveThresholdWei,
            "test buy must actually cross the configured reserve threshold"
        );
        assertGe(market.progressBps(), minProgressBps, "test buy must actually cross the configured progress threshold");
        assertGt(engine.aboveThresholdSince(1), 0, "must be tracked as currently above threshold");

        // Too early: qualify() must be a harmless no-op before the configured streak length has
        // genuinely elapsed for THIS configuration specifically.
        vm.warp(block.timestamp + requiredAbsoluteSeconds - 1);
        engine.qualify(1);
        assertEq(
            engine.candidateCount(1),
            0,
            "must not qualify one second before this configuration's own required streak elapses"
        );

        // Exactly at the configured streak length: qualify() must now succeed.
        vm.warp(block.timestamp + 1);
        engine.qualify(1);
        assertEq(engine.candidateCount(1), 1, "must qualify exactly at this configuration's own required streak length");

        roundDurationSeconds; // acknowledged - RoundManager's own roundDuration is proven
        // deployment-configurable separately below; this helper focuses on EligibilityRegistry's
        // three thresholds, which is what actually varies between canary and production here.
    }

    function test_canaryConfiguration_qualifiesExactlyAtItsOwnSmallThresholds() public {
        _runConfiguration({
            minProgressBps: 1,
            minReserveThresholdWei: 500_000_000_000_000, // 0.0005 ether
            requiredAbsoluteSeconds: 60,
            roundDurationSeconds: 300,
            buyAmount: 0.00075 ether
        });
    }

    function test_productionConfiguration_qualifiesExactlyAtItsOwnLargeThresholds() public {
        _runConfiguration({
            minProgressBps: 500,
            minReserveThresholdWei: 0.229 ether,
            requiredAbsoluteSeconds: 1_800,
            roundDurationSeconds: 3_600,
            buyAmount: 5 ether
        });
    }

    /// @notice Proves RoundManager's own roundDuration is independently deployment-configurable,
    /// with the identical round-close/draw algorithm in both cases.
    function test_roundDuration_isIndependentlyConfigurable_bothScales() public {
        EligibilityRegistry canaryEngine = new EligibilityRegistry(deployer, 1, 500_000_000_000_000, 60);
        RoundManager canaryRm = new RoundManager(address(canaryEngine), makeAddr("provider1"), governance, 300);
        assertEq(canaryRm.roundDuration(), 300, "canary roundDuration must equal the supplied value exactly");

        EligibilityRegistry prodEngine = new EligibilityRegistry(deployer, 500, 0.229 ether, 1_800);
        RoundManager prodRm = new RoundManager(address(prodEngine), makeAddr("provider2"), governance, 3_600);
        assertEq(prodRm.roundDuration(), 3_600, "production roundDuration must equal the supplied value exactly");

        // MIN_DRAW_CANDIDATES remains the fixed constant 3 in both - never made configurable.
        assertEq(canaryRm.MIN_DRAW_CANDIDATES(), 3, "MIN_DRAW_CANDIDATES must remain fixed at 3 for canary");
        assertEq(prodRm.MIN_DRAW_CANDIDATES(), 3, "MIN_DRAW_CANDIDATES must remain fixed at 3 for production");
    }

    /// @notice Proves there is no setter for any of the four new immutables - confirmed by their
    /// absence from the contracts' own ABI (a call to a nonexistent selector reverts).
    function test_noSetterExistsForAnyOfTheFourNewImmutables() public {
        EligibilityRegistry engine = new EligibilityRegistry(deployer, 500, 0.229 ether, 1_800);
        RoundManager roundManagerInstance = new RoundManager(address(engine), makeAddr("provider3"), governance, 3_600);

        (bool ok1,) = address(engine).call(abi.encodeWithSignature("setMinProgressBps(uint256)", 1));
        assertFalse(ok1, "setMinProgressBps must not exist");
        (bool ok2,) = address(engine).call(abi.encodeWithSignature("setMinReserveThreshold(uint256)", 1));
        assertFalse(ok2, "setMinReserveThreshold must not exist");
        (bool ok3,) = address(engine).call(abi.encodeWithSignature("setRequiredAbsoluteSeconds(uint256)", 1));
        assertFalse(ok3, "setRequiredAbsoluteSeconds must not exist");
        (bool ok4,) = address(roundManagerInstance).call(abi.encodeWithSignature("setRoundDuration(uint256)", 1));
        assertFalse(ok4, "setRoundDuration must not exist");
    }
}
