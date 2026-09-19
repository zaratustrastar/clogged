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
///         Safe's address as config and wires it in purely as the protocol fee recipient; the
///         Safe holds no timelock role at all -- see the governance-topology note below).
///
/// @dev ALL CHAIN-SPECIFIC/EXTERNAL ADDRESSES COME FROM ENVIRONMENT VARIABLES, never hardcoded
///      here: CCIP router, Arbitrum chain selector, the Safe address, curve config, etc. This
///      keeps deployment config separate from contract/script source.
///
/// @dev GOVERNANCE TOPOLOGY: the Safe is treasury/fee-recipient ONLY -- it holds no timelock
///      role whatsoever. The sole Timelock PROPOSER_ROLE (and, since OpenZeppelin's
///      TimelockController constructor grants both to every address in the `proposers` array --
///      confirmed directly in the vendored source, not assumed -- CANCELLER_ROLE too) belongs to
///      GOVERNANCE_PROPOSER_ADDRESS, an explicit, required env var -- never inferred from
///      msg.sender/Foundry's own broadcast-sender behavior, which would silently grant this
///      privilege to whichever address happens to sign the deployment transaction rather than a
///      deliberately chosen operator address. Executor stays open (address(0) grant -- "Granting
///      a role to address(0) is equivalent to enabling this role for everyone," per
///      TimelockController's own onlyRoleOrOpenRole doc comment), and the timelock still
///      self-administers (admin = address(0) passed to the constructor; DEFAULT_ADMIN_ROLE is
///      granted only to the timelock contract itself, confirmed directly in the vendored
///      constructor). Neither the Safe nor the governance proposer ever holds admin.
///
/// @dev TIMELOCK DELAY IS DEPLOYMENT-CONFIGURABLE, READ FROM TIMELOCK_DELAY_SECONDS (required, no
///      default -- vm.envUint reverts loudly if this isn't set, verified directly rather than
///      assumed). Setting TIMELOCK_DELAY_SECONDS=0 removes the WAIT, not the PROCESS: every
///      action still requires the governance proposer to schedule it and still passes through
///      the same schedule/execute mechanism -- it just becomes executable immediately rather
///      than after a fixed delay. The delay can be changed later via
///      TimelockController.updateDelay(newDelay), itself a timelocked governance action gated by
///      the currently configured delay.
///
/// @dev GOVERNANCE IS SET AT CONSTRUCTION, WITH NO TRANSFER PATH AFTERWARD (by design -- see
///      RoundManager/BondingCurveClog: `governance` is assigned once in the constructor and never
///      reassigned anywhere in either contract). This script therefore sets `governance =
///      address(timelock)` immediately, for every contract, rather than a deployer-first bootstrap
///      later "handed off" -- there is no hand-off mechanism to rely on, and adding one purely to
///      ease deployment would be a real, permanent attack surface for a temporary convenience.
///      The direct consequence: even day-one wiring that happens to be gated by `onlyGovernance`
///      (RoundManager.setRewardVault, ChainlinkRandomnessProvider.setWrapper) must go through the
///      real timelock process from the very first deployment, with no special-cased bypass. This
///      script deploys everything and VERIFIES the parts that don't need governance, then logs the
///      exact governance actions (target, calldata) the governance proposer must schedule next --
///      it does not attempt to schedule or execute them itself.
contract DeployRobinhoodChain is Script {
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
        // Treasury/fee recipient ONLY -- never wired into any timelock role below.
        address safe = vm.envAddress("SAFE_ADDRESS");
        address multisig = vm.envAddress("FEE_MULTISIG_ADDRESS"); // 10% trading-tax/launch-fee recipient
        string memory tickerNFTBaseURI = vm.envString("TICKER_NFT_BASE_URI");
        // Required, no default: an operator who forgets to set this gets a clear revert here,
        // never a silent 48-hour (or any other unintended) delay.
        uint256 timelockDelay = vm.envUint("TIMELOCK_DELAY_SECONDS");
        // The sole Timelock proposer/canceller -- an explicit, required env var, never
        // msg.sender. See the contract-level governance-topology note above for why.
        address governanceProposer = vm.envAddress("GOVERNANCE_PROPOSER_ADDRESS");

        vm.startBroadcast();

        // Timelock first: it becomes "governance" for everything deployed after it. Admin role
        // is address(0) -- the timelock self-administers, so no single EOA or even the governance
        // proposer can bypass the configured delay to change who may propose/execute. Executors =
        // address(0) means anyone may execute an already-queued, already-delayed action --
        // purely mechanical once public and pending, so permissionless execution costs nothing
        // in safety.
        address[] memory proposers = new address[](1);
        proposers[0] = governanceProposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        d.timelock = new TimelockController(timelockDelay, proposers, executors, address(0));
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
        // The name/symbol below are the ERC-721's own immutable constructor args - they can
        // never be changed after deployment, so get them right before running this script for
        // real. (An earlier deployment of this contract used "PMFI Casino Tickers" here - a
        // copy-paste leftover from an unrelated project - which is now permanently baked into
        // that already-live contract's own name() and cannot be fixed without deploying an
        // entirely new TickerNFT and re-wiring every existing minted ticker NFT to it.)
        d.tickerNFT = new TickerNFT("CLOG Ticker Labels", "TICKER", msg.sender, tickerNFTBaseURI);
        d.tickerRegistry = new TickerRegistry(
            address(d.engine),
            address(d.tickerNFT),
            multisig,
            address(d.rewardVault),
            governance,
            VIRTUAL_ETH_SEED,
            BUFFER_BPS
        );
        d.tickerNFT.setRegistry(address(d.tickerRegistry)); // one-time; deployer's TickerNFT
        // privilege is fully consumed by this single call, forever, immediately

        vm.stopBroadcast();

        _verify(d);
        _logSummary(d);
        _logRequiredGovernanceActions(d);
    }

    /// @notice Checks that don't depend on the timelock's configured delay having elapsed -- run
    ///         automatically as part of `run()`, not a separate manual step that could be skipped.
    ///         Fails loudly (reverts the whole deployment) if any configuration is wrong.
    function _verify(Deployment memory d) internal view {
        // -- Tickers --
        require(d.tickerRegistry.MAX_PUBLIC_TICKERS() == 7_777, "cap mismatch");
        require(d.tickerRegistry.RESERVED_CLOG_KEY() == keccak256(bytes("CLOG")), "CLOG reservation mismatch");
        require(d.tickerRegistry.publicTickerCount() == 0, "public ticker count must start at zero");
        require(d.tickerRegistry.LAUNCH_PRICE() == 0.002 ether, "launch price mismatch");
        // Every meme TickerRegistry ever launches passes this exact, immutable address straight
        // into its new BondingCurveClog's constructor (see TickerRegistry._launchMeme) -- this is
        // the strongest verification available pre-launch that every future meme's eligibility
        // wiring will be correct, since no meme has been launched yet to check directly.
        require(
            address(d.tickerRegistry.eligibilityRegistry()) == address(d.engine),
            "TickerRegistry not wired to the correct EligibilityRegistry -- every future launch would receive the wrong one"
        );

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
        require(
            d.timelock.getMinDelay() == vm.envUint("TIMELOCK_DELAY_SECONDS"),
            "timelock delay must match the configured TIMELOCK_DELAY_SECONDS"
        );

        address governanceProposer = vm.envAddress("GOVERNANCE_PROPOSER_ADDRESS");
        address safeAddr = vm.envAddress("SAFE_ADDRESS");

        // The governance proposer holds exactly proposer + canceller -- never executor
        // (individually; the open address(0) grant below covers everyone including this address,
        // so it never needs its own explicit grant) and never admin.
        require(
            d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), governanceProposer),
            "governance proposer must hold proposer role"
        );
        require(
            d.timelock.hasRole(d.timelock.CANCELLER_ROLE(), governanceProposer),
            "governance proposer must hold canceller role"
        );
        require(
            !d.timelock.hasRole(d.timelock.EXECUTOR_ROLE(), governanceProposer),
            "governance proposer must not individually hold executor role"
        );
        require(
            !d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), governanceProposer),
            "governance proposer must not hold admin role"
        );

        // The Safe is treasury/fee-recipient ONLY -- confirmed to hold zero timelock privilege.
        require(!d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), safeAddr), "Safe must NOT hold proposer role");
        require(!d.timelock.hasRole(d.timelock.CANCELLER_ROLE(), safeAddr), "Safe must NOT hold canceller role");
        require(!d.timelock.hasRole(d.timelock.EXECUTOR_ROLE(), safeAddr), "Safe must NOT hold executor role");
        require(!d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), safeAddr), "Safe must NOT hold admin role");

        // Open executor: granting EXECUTOR_ROLE to address(0) is what makes execution
        // permissionless for everyone (see TimelockController's own onlyRoleOrOpenRole doc
        // comment) -- confirmed directly rather than inferred from any single address's own role.
        require(d.timelock.hasRole(d.timelock.EXECUTOR_ROLE(), address(0)), "executor must remain open");

        // Fee recipient invariant: the Safe passed in as FEE_MULTISIG_ADDRESS is the exact
        // address TickerRegistry actually pays -- the one privilege the Safe is meant to have.
        require(
            safeAddr == vm.envAddress("FEE_MULTISIG_ADDRESS"),
            "SAFE_ADDRESS and FEE_MULTISIG_ADDRESS must be the same address"
        );
        require(d.tickerRegistry.multisig() == safeAddr, "Safe must be the fee recipient wired into TickerRegistry");

        require(d.engine.roundManager() == address(d.roundManager), "engine's one-time RoundManager wiring incomplete");
        require(
            d.randomnessProvider.roundManager() == address(d.roundManager),
            "provider's one-time RoundManager wiring incomplete"
        );

        // -- Randomness --
        require(
            address(d.roundManager.randomnessProvider()) == address(d.randomnessProvider),
            "RoundManager not pointed at provider"
        );
        require(address(d.roundManager.engine()) == address(d.engine), "RoundManager not pointed at engine");
        require(
            d.randomnessProvider.getRouter() == vm.envAddress("CCIP_ROUTER_ROBINHOOD"), "provider CCIP router mismatch"
        );
        require(
            d.randomnessProvider.arbitrumChainSelector() == uint64(vm.envUint("ARBITRUM_CHAIN_SELECTOR")),
            "provider Arbitrum selector mismatch"
        );

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
    ///      propose -> configured delay -> execute path. This just tells the operator exactly
    ///      what to queue; it does not (and cannot) queue or execute anything itself.
    function _logRequiredGovernanceActions(Deployment memory d) internal view {
        console2.log("=== Required governance actions (queue via the governance proposer, through the timelock) ===");
        console2.log("1) RoundManager.setRewardVault(rewardVault) -- target:", address(d.roundManager));
        console2.logBytes(abi.encodeCall(RoundManager.setRewardVault, (address(d.rewardVault))));
        console2.log(
            "2) ChainlinkRandomnessProvider.setWrapper(wrapperOnArbitrum) -- target:", address(d.randomnessProvider)
        );
        console2.log(
            "   (wrapper address known only after DeployArbitrumWrapper.s.sol runs -- queue this once it exists)"
        );
        console2.log("NOTE: the protocol is not fully operational (no draws can resolve) until both");
        console2.log("of these clear the configured timelock delay (currently:", vm.envUint("TIMELOCK_DELAY_SECONDS"));
        console2.log("seconds) and are executed.");
        console2.log("");
        console2.log("=== Funding requirement (ongoing, not one-time) ===");
        console2.log("ChainlinkRandomnessProvider must hold ETH to pay the outbound CCIP fee every time");
        console2.log("RoundManager.closeRoundAndOpenNext() or requestRandomnessForRound() requests randomness --");
        console2.log("target:", address(d.randomnessProvider));
        console2.log("If this balance runs out, the round still closes and the next one still opens (see");
        console2.log("RoundManager's decoupled request handling) -- only the randomness request itself fails");
        console2.log("and becomes retryable via requestRandomnessForRound() once topped up. No specific amount");
        console2.log("is prescribed here -- it depends on live CCIP fee pricing at request time, which this");
        console2.log("script has no way to know in advance; fund it, monitor it, and top it up as needed.");
    }
}
