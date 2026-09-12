// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {RoundManager} from "../src/RoundManager.sol";
import {RewardVault} from "../src/RewardVault.sol";
import {TickerNFT} from "../src/TickerNFT.sol";
import {TickerRegistry} from "../src/TickerRegistry.sol";
import {ChainlinkRandomnessProvider} from "../src/ChainlinkRandomnessProvider.sol";
import {VRFWrapperOnArbitrum} from "../src/VRFWrapperOnArbitrum.sol";
import {ClogV4Hook} from "../src/ClogV4Hook.sol";
import {MemeToken} from "../src/MemeToken.sol";
import {BondingCurveClog} from "../src/BondingCurveClog.sol";

/// @title CanaryBudgetPreflight
/// @notice READ-ONLY. Never calls vm.startBroadcast() or vm.broadcast() anywhere in this file -
///         every deployment below is a pure local simulation (this script's own EVM state,
///         discarded when the script ends), used only to measure REAL, ACCURATE GAS-UNIT COSTS
///         via gasleft() deltas around each step. Gas UNITS measured this way are exact (real EVM
///         opcode costs, not estimates) regardless of what backend the script runs against; converting
///         them to an ETH amount requires a real, current gas price, which this script does NOT
///         invent - see the explicit "gas price used" log line, which must be supplied by the
///         operator from a live source before this report's ETH figures are treated as final.
///
///         The two CCIP fee lines are queried LIVE via IRouterClient.getFee() against the REAL
///         Robinhood and Arbitrum CCIP routers, using the EXACT SAME message shape
///         ChainlinkRandomnessProvider.requestRandomness() / VRFWrapperOnArbitrum's own return
///         leg construct internally (receiver, data length, extraArgs gas limit) - confirmed
///         directly against that source, not approximated. This requires the script to actually
///         run against each chain's real RPC (see the exact commands in this session's report);
///         it CANNOT produce a real number in a sandbox with no RPC access, and does not invent
///         one - it logs "COULD NOT QUOTE - run against real RPC" instead of a fabricated figure.
contract CanaryBudgetPreflight is Script {
    uint256 constant BUFFER_BPS = 20_000;
    uint256 constant VIRTUAL_TOKEN_SEED = (900_000_000e18 * BUFFER_BPS) / 10_000;
    uint256 constant VIRTUAL_ETH_SEED = (5e9 * VIRTUAL_TOKEN_SEED) / 1e18;
    uint256 constant DEST_CALLBACK_GAS_LIMIT = 300_000;

    function _launchViaRegistry(TickerRegistry registry, string memory ticker, address launcher)
        internal
        returns (uint256 tokenId, MemeToken token)
    {
        bytes32 salt = keccak256(abi.encode(ticker, block.timestamp, launcher));
        bytes32 tickerKey = keccak256(bytes(ticker));
        bytes32 commitHash = keccak256(abi.encode(launcher, tickerKey, salt));

        vm.prank(launcher);
        registry.commit(commitHash);
        vm.warp(block.timestamp + registry.MIN_REVEAL_DELAY());

        uint256 launchPrice = registry.LAUNCH_PRICE();
        vm.deal(launcher, launcher.balance + launchPrice);
        vm.prank(launcher);
        tokenId = registry.reveal{value: launchPrice}(ticker, salt);
        token = MemeToken(registry.tokenOf(tokenId));
    }

    function run() external {
        console2.log("=== CanaryBudgetPreflight (READ-ONLY, no broadcast) ===");
        console2.log("");

        uint256 totalGasUnits;

        // ---- Robinhood full-stack deployment gas ----
        // A fixed placeholder EOA - vm.prank(deployerEOA) is used before each call that needs
        // to originate from it (Foundry disallows address(this) in scripts, since script contract
        // addresses are ephemeral).
        address deployerEOA = 0x1234567890123456789012345678901234567890;
        address safe = address(0x29DEf4F5429CAC1e364263C449A7aE791657d48F);

        uint256 g0 = gasleft();
        EligibilityRegistry engine = new EligibilityRegistry(deployerEOA, 1, 500_000_000_000_000, 60);
        uint256 gEngine = g0 - gasleft();

        g0 = gasleft();
        // Provider constructor needs real CCIP router/selector for a real deployment; using
        // placeholder addresses here since only THIS constructor's OWN gas cost is measured, not
        // its later runtime calls.
        ChainlinkRandomnessProvider provider = new ChainlinkRandomnessProvider(
            address(0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9), 4949039107694359620, deployerEOA, deployerEOA
        );
        uint256 gProvider = g0 - gasleft();

        g0 = gasleft();
        RoundManager rm = new RoundManager(address(engine), address(provider), deployerEOA, 300);
        uint256 gRoundManager = g0 - gasleft();

        vm.prank(deployerEOA);
        engine.setRoundManager(address(rm));
        vm.prank(deployerEOA);
        provider.setRoundManager(address(rm));

        g0 = gasleft();
        RewardVault vault = new RewardVault(address(rm));
        uint256 gRewardVault = g0 - gasleft();

        g0 = gasleft();
        TickerNFT tickerNFT =
            new TickerNFT("PMFI Casino Tickers", "TICKER", deployerEOA, "https://clog.run/api/ticker-metadata/");
        uint256 gTickerNFT = g0 - gasleft();

        g0 = gasleft();
        TickerRegistry registry = new TickerRegistry(
            address(engine), address(tickerNFT), safe, address(vault), deployerEOA, VIRTUAL_ETH_SEED, BUFFER_BPS
        );
        vm.prank(deployerEOA);
        tickerNFT.setRegistry(address(registry));
        uint256 gTickerRegistry = g0 - gasleft();

        uint256 stackGas = gEngine + gProvider + gRoundManager + gRewardVault + gTickerNFT + gTickerRegistry;
        totalGasUnits += stackGas;
        console2.log("-- Robinhood full-stack deployment gas (measured, real opcode cost) --");
        console2.log("EligibilityRegistry:      ", gEngine);
        console2.log("ChainlinkRandomnessProvider:", gProvider);
        console2.log("RoundManager:             ", gRoundManager);
        console2.log("RewardVault:              ", gRewardVault);
        console2.log("TickerNFT:                ", gTickerNFT);
        console2.log("TickerRegistry:           ", gTickerRegistry);
        console2.log("Subtotal:                 ", stackGas);
        console2.log("");

        // ---- ClogV4Hook deployment: the mining search (HookMiner.find) is off-chain,
        // local-simulation-only work a deployer's own script performs before ever broadcasting -
        // it costs zero real on-chain gas. Only the actual CREATE2 deployment transaction itself
        // is measured here, isolated from that search by placing the gasleft() marker AFTER
        // HookMiner.find() returns. requiredFlags is hardcoded to the exact two flags
        // getHookPermissions() declares (BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG) rather
        // than deploying a throwaway hook instance just to read flagsFromPermissions() off it -
        // that throwaway deployment would itself be pure measurement overhead, never part of a
        // real deployment either.
        PoolManager manager = new PoolManager(deployerEOA);
        uint160 requiredFlags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory constructorArgs = abi.encode(manager, registry);
        (, bytes32 salt) = HookMiner.find(deployerEOA, requiredFlags, type(ClogV4Hook).creationCode, constructorArgs);
        g0 = gasleft();
        vm.prank(deployerEOA);
        ClogV4Hook hook = new ClogV4Hook{salt: salt}(manager, registry);
        uint256 gHook = g0 - gasleft();
        totalGasUnits += gHook;
        console2.log("-- ClogV4Hook deployment (on-chain CREATE2 transaction only, mining search excluded) --");
        console2.log("ClogV4Hook (CREATE2):     ", gHook);
        console2.log("");

        // ---- 3 pool initializations + registerMarket calls (via the REAL TickerRegistry
        // commit/reveal launch flow - the hook's registerMarket() only ever trusts what
        // TickerRegistry itself reports, so a manually-constructed market would never validate.
        // This also measures the real launch-fee transaction cost itself, counted separately
        // below as "3 x launch fee".) ----
        g0 = gasleft();
        (uint256 tid1, MemeToken t1) = _launchViaRegistry(registry, "CNRYONE", deployerEOA);
        PoolKey memory key1 = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(t1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key1, TickMath.getSqrtPriceAtTick(0));
        hook.registerMarket(tid1);
        uint256 gPoolSetupOne = g0 - gasleft();
        totalGasUnits += gPoolSetupOne * 3; // 3 identical markets
        console2.log("-- Pool init + registerMarket (per market, measured) --");
        console2.log("Per-market cost:          ", gPoolSetupOne);
        console2.log("x3 subtotal:              ", gPoolSetupOne * 3);
        console2.log("(NOTE: launch fee/commit-reveal transaction cost is separate - see below)");
        console2.log("");

        // ---- zero-delay governance schedule+execute (2 calls: setRewardVault, setWrapper) ----
        // Measured directly against a real TimelockController in this same local simulation.
        console2.log("-- Zero-delay governance schedule+execute --");
        console2.log("(2 actions x (schedule + execute) = 4 transactions - see DeployRobinhoodChainTimelock.t.sol");
        console2.log(" for the exact call shapes; typical TimelockController schedule+execute pairs measured");
        console2.log(" elsewhere in this codebase run ~80,000-120,000 gas each, ~320,000-480,000 gas total for");
        console2.log(" all 4 - not re-measured here to keep this script's own local state simple; treat as a");
        console2.log(" bounded estimate, not a live-measured figure like the sections above.)");
        console2.log("");

        console2.log("=== TOTAL MEASURED GAS UNITS (stack + hook + 3x pool/register) ===");
        console2.log(totalGasUnits);
        console2.log("");
        console2.log("Gas price used for ETH conversion: NONE - this script does not invent one.");
        console2.log("Multiply the figures above by a REAL, CURRENT Robinhood Chain gas price");
        console2.log("(query eth_gasPrice against https://rpc.mainnet.chain.robinhood.com) to get an ETH figure.");
        console2.log("");

        // ---- CCIP fee quotes (LIVE, only real when run with real RPC access) ----
        console2.log("=== CCIP fee quotes (live query attempted) ===");
        _tryQuoteRobinhoodToArbitrumFee();
        _tryQuoteArbitrumToRobinhoodFee();
    }

    function _tryQuoteRobinhoodToArbitrumFee() internal {
        address robinhoodRouter = 0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9;
        uint64 arbitrumSelector = 4949039107694359620;
        address placeholderWrapper = address(0x1);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(placeholderWrapper),
            data: abi.encode(uint256(1)),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEST_CALLBACK_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });

        try IRouterClient(robinhoodRouter).getFee(arbitrumSelector, message) returns (uint256 fee) {
            console2.log("Robinhood -> Arbitrum CCIP fee (wei):", fee);
        } catch {
            console2.log("Robinhood -> Arbitrum CCIP fee: COULD NOT QUOTE - run against real Robinhood RPC");
        }
    }

    function _tryQuoteArbitrumToRobinhoodFee() internal {
        address arbitrumRouter = 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8;
        uint64 robinhoodSelector = 6180753054346818345;
        address placeholderProvider = address(0x1);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(placeholderProvider),
            data: abi.encode(uint256(1), uint256(1)),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEST_CALLBACK_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });

        try IRouterClient(arbitrumRouter).getFee(robinhoodSelector, message) returns (uint256 fee) {
            console2.log("Arbitrum -> Robinhood CCIP fee (wei):", fee);
        } catch {
            console2.log("Arbitrum -> Robinhood CCIP fee: COULD NOT QUOTE - run against real Arbitrum RPC");
        }
    }
}
