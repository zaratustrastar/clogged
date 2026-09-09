// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {RoundManager} from "../src/RoundManager.sol";
import {RewardVault} from "../src/RewardVault.sol";
import {TickerNFT} from "../src/TickerNFT.sol";
import {TickerRegistry} from "../src/TickerRegistry.sol";
import {ChainlinkRandomnessProvider} from "../src/ChainlinkRandomnessProvider.sol";

/// @title DeployRobinhoodChain
/// @notice Deploys the full Robinhood-Chain side of the protocol: EligibilityRegistry,
///         RoundManager, RewardVault, TickerNFT, TickerRegistry, ChainlinkRandomnessProvider, and
///         the TimelockController that becomes "governance" everywhere. Does NOT deploy
///         VRFWrapperOnArbitrum (separate chain, separate script -- see
///         DeployArbitrumWrapper.s.sol) or a Safe (Safe multisigs are created via Safe's own
///         infrastructure/UI, not custom Solidity -- this script only takes an already-created
///         Safe's address as config and wires it in as the timelock's proposer).
///
/// @dev ALL CHAIN-SPECIFIC/EXTERNAL ADDRESSES COME FROM ENVIRONMENT VARIABLES, never hardcoded
///      here: CCIP router, Arbitrum chain selector, the Safe address, curve config, etc. This
///      keeps deployment config separate from contract/script source.
///
/// @dev GOVERNANCE IS SET AT CONSTRUCTION, WITH NO TRANSFER PATH AFTERWARD (by design -- see
///      RoundManager/BondingCurveClog: `governance` is assigned once in the constructor and never
///      reassigned anywhere in either contract). This script therefore sets `governance =
///      address(timelock)` immediately, for every contract, rather than a deployer-first bootstrap
///      later "handed off" -- there is no hand-off mechanism to rely on, and adding one purely to
///      ease deployment would be a real, permanent attack surface for a temporary convenience.
///      The direct consequence: even day-one wiring that happens to be gated by `onlyGovernance`
///      (RoundManager.setRewardVault, ChainlinkRandomnessProvider.setWrapper) must go through the
///      real 48-hour timelock process from the very first deployment, with no special-cased
///      bypass. This script deploys everything and VERIFIES the parts that don't need governance,
///      then logs the exact governance actions (target, calldata) the Safe must queue next -- it
///      does not attempt to execute or simulate them, since a real Safe requires actual multisig
///      approval this script cannot produce.
contract DeployRobinhoodChain is Script {
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    // Config G curve parameters (see architecture docs) -- override via env if a different curve
    // config is ever selected for a given deployment.
    uint256 public constant BUFFER_BPS = 20_000; // 2.0x
    uint256 public constant VIRTUAL_TOKEN_SEED = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 public constant VIRTUAL_ETH_SEED = (5e9 * VIRTUAL_TOKEN_SEED) / 1e18; // P0 = 5e-9 ETH/token

    struct Deployment {
        EligibilityRegistry engine;
        RoundManager roundManager;
        RewardVault rewardVault;
        TickerNFT tickerNFT;
        TickerRegistry tickerRegistry;
        ChainlinkRandomnessProvider randomnessProvider;
        TimelockController timelock;
    }

    function run() external returns (Deployment memory d) {
        address ccipRouter = vm.envAddress("CCIP_ROUTER_ROBINHOOD");
        uint64 arbitrumChainSelector = uint64(vm.envUint("ARBITRUM_CHAIN_SELECTOR"));
        address safe = vm.envAddress("SAFE_ADDRESS");
        address multisig = vm.envAddress("FEE_MULTISIG_ADDRESS"); // 10% trading-tax/launch-fee recipient
        string memory tickerNFTBaseURI = vm.envString("TICKER_NFT_BASE_URI");

        vm.startBroadcast();

        // Timelock first: it becomes "governance" for everything deployed after it. Admin role
        // is address(0) -- the timelock self-administers, so no single EOA or even the Safe can
        // bypass the 48h delay to change who may propose/execute. Executors = address(0) means
        // anyone may execute an already-queued, already-delayed action -- purely mechanical once
        // public and pending, so permissionless execution costs nothing in safety.
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        d.timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));
        address governance = address(d.timelock);

        // engine and provider are deployed first (deployer authorized to wire RoundManager back
        // via a one-time setter), RoundManager second using their real, already-known addresses
        // directly. No CREATE-nonce address prediction anywhere in this flow.
        d.engine = new EligibilityRegistry(msg.sender);
        d.randomnessProvider =
            new ChainlinkRandomnessProvider(ccipRouter, arbitrumChainSelector, governance, msg.sender);
        d.roundManager = new RoundManager(address(d.engine), address(d.randomnessProvider), governance);
        d.engine.setRoundManager(address(d.roundManager));
        d.randomnessProvider.setRoundManager(address(d.roundManager));

        d.rewardVault = new RewardVault(address(d.roundManager));

        // TickerNFT/TickerRegistry circular dependency, same one-time-setter pattern used
        // throughout: deploy TickerNFT first (deployer authorized to initialize it once), deploy
        // TickerRegistry second (real TickerNFT address, no prediction needed), then lock it in.
        d.tickerNFT = new TickerNFT("PMFI Casino Tickers", "TICKER", msg.sender, tickerNFTBaseURI);
        d.tickerRegistry = new TickerRegistry(
            address(d.engine), address(d.tickerNFT), multisig, address(d.rewardVault), governance, VIRTUAL_ETH_SEED, BUFFER_BPS
        );
        d.tickerNFT.setRegistry(address(d.tickerRegistry)); // one-time; deployer's TickerNFT
            // privilege is fully consumed by this single call, forever, immediately

        vm.stopBroadcast();

        _verify(d);
        _logSummary(d);
        _logRequiredGovernanceActions(d);
    }

    /// @notice Checks that don't depend on the timelock's 48h delay having elapsed -- run
    ///         automatically as part of `run()`, not a separate manual step that could be skipped.
    ///         Fails loudly (reverts the whole deployment) if any configuration is wrong.
    function _verify(Deployment memory d) internal view {
        // -- Tickers --
        require(d.tickerRegistry.MAX_PUBLIC_TICKERS() == 7_777, "cap mismatch");
        require(d.tickerRegistry.RESERVED_CLOG_KEY() == keccak256(bytes("CLOG")), "CLOG reservation mismatch");
        require(d.tickerRegistry.publicTickerCount() == 0, "public ticker count must start at zero");
        require(d.tickerRegistry.LAUNCH_PRICE() == 0.002 ether, "launch price mismatch");

        // -- TickerNFT --
        require(d.tickerNFT.tickerRegistry() == address(d.tickerRegistry), "TickerNFT not wired to registry");
        require(d.tickerNFT.tickerRegistry() != msg.sender, "deployer must not itself be the authorized minter");
        // setRegistry's own guard (require registry == address(0)) means the one-time
        // initialization privilege the `deployer` slot granted can never be exercised again by
        // anyone, now that it's non-zero -- confirmed structurally, not just by this read.
        require(d.tickerNFT.tickerRegistry() != address(0), "TickerNFT registry must be locked in by now");

        // -- Governance --
        require(d.roundManager.governance() == address(d.timelock), "RoundManager governance not timelock");
        require(d.randomnessProvider.governance() == address(d.timelock), "provider governance not timelock");
        require(d.tickerRegistry.governance() == address(d.timelock), "TickerRegistry governance not timelock");
        require(d.timelock.getMinDelay() == TIMELOCK_DELAY, "timelock delay must be 48h");
        require(d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), vm.envAddress("SAFE_ADDRESS")), "Safe must hold proposer role");
        require(!d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), msg.sender), "deployer must not hold proposer role");
        require(!d.timelock.hasRole(d.timelock.EXECUTOR_ROLE(), msg.sender), "deployer must not hold executor role");
        require(!d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), msg.sender), "deployer must not hold admin role");
        require(d.engine.roundManager() == address(d.roundManager), "engine's one-time RoundManager wiring incomplete");
        require(d.randomnessProvider.roundManager() == address(d.roundManager), "provider's one-time RoundManager wiring incomplete");

        // -- Randomness --
        require(address(d.roundManager.randomnessProvider()) == address(d.randomnessProvider), "RoundManager not pointed at provider");
        require(address(d.roundManager.engine()) == address(d.engine), "RoundManager not pointed at engine");
        require(d.randomnessProvider.getRouter() == vm.envAddress("CCIP_ROUTER_ROBINHOOD"), "provider CCIP router mismatch");
        require(d.randomnessProvider.arbitrumChainSelector() == uint64(vm.envUint("ARBITRUM_CHAIN_SELECTOR")), "provider Arbitrum selector mismatch");

        // -- Rewards --
        require(d.rewardVault.roundManager() == address(d.roundManager), "RewardVault not pointed at RoundManager");
        require(d.rewardVault.CLAIM_WINDOW() == 90 days, "claim window must be 90 days");
    }

    function _logSummary(Deployment memory d) internal view {
        console2.log("=== Robinhood Chain Deployment Summary ===");
        console2.log("Timelock (governance):", address(d.timelock));
        console2.log("EligibilityRegistry:", address(d.engine));
        console2.log("RoundManager:", address(d.roundManager));
        console2.log("RewardVault:", address(d.rewardVault));
        console2.log("TickerNFT:", address(d.tickerNFT));
        console2.log("TickerRegistry:", address(d.tickerRegistry));
        console2.log("ChainlinkRandomnessProvider:", address(d.randomnessProvider));
    }

    /// @dev Governance is set to the timelock from construction, with no bootstrap bypass (see
    ///      contract-level notes), so day-one wiring genuinely has to go through the real
    ///      propose -> 48h delay -> execute path. This just tells the operator exactly what to
    ///      queue; it does not (and cannot) queue or execute anything itself.
    function _logRequiredGovernanceActions(Deployment memory d) internal pure {
        console2.log("=== Required governance actions (queue via the Safe, through the timelock) ===");
        console2.log("1) RoundManager.setRewardVault(rewardVault) -- target:", address(d.roundManager));
        console2.logBytes(abi.encodeCall(RoundManager.setRewardVault, (address(d.rewardVault))));
        console2.log("2) ChainlinkRandomnessProvider.setWrapper(wrapperOnArbitrum) -- target:", address(d.randomnessProvider));
        console2.log("   (wrapper address known only after DeployArbitrumWrapper.s.sol runs -- queue this once it exists)");
        console2.log("NOTE: the protocol is not fully operational (no draws can resolve) until both");
        console2.log("of these clear the 48h timelock and are executed.");
    }
}
