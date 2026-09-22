// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";
import {TickerNFT} from "../src/TickerNFT.sol";
import {RewardVault} from "../src/RewardVault.sol";

import {TickerRegistryV4} from "../src-v4/TickerRegistryV4.sol";
import {ClogV4HookV2} from "../src-v4/ClogV4HookV2.sol";
import {HookMinerV2} from "../test-v4/utils/HookMinerV2.sol";

contract DeployV4CanaryV2 is Script {
    address constant POOL_MANAGER =
        0x8366a39CC670B4001A1121B8F6A443A643e40951;

    address constant CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    address constant REQUIRED_FEE_SAFE =
        0x29DEf4F5429CAC1e364263C449A7aE791657d48F;

    uint160 constant REQUIRED_HOOK_MASK = 0x2AC8;
    uint160 constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_BPS = 20_000;

    // Disposable live canary only — NOT production qualification settings.
    uint256 constant CANARY_MIN_PROGRESS_BPS = 4;
    uint256 constant CANARY_MIN_RESERVE = 0.003 ether;
    uint256 constant CANARY_REQUIRED_SECONDS = 60;

    function run()
        external
        returns (
            EligibilityRegistry eligibility,
            TickerNFT tickerNFT,
            TickerRegistryV4 registry,
            ClogV4HookV2 hook,
            RewardVault rewardVault
        )
    {
        require(block.chainid == 4663, "wrong chain");
        require(POOL_MANAGER.code.length > 0, "PoolManager missing");

        address deployer = vm.envAddress("CANARY_DEPLOYER");
        address feeSafe = vm.envAddress("FEE_MULTISIG_ADDRESS");
        address sentinelManager = vm.envAddress("SENTINEL_MANAGER_ADDRESS");
        string memory baseURI = vm.envString("TICKER_NFT_BASE_URI");

        require(deployer != address(0), "CANARY_DEPLOYER missing");
        require(feeSafe == REQUIRED_FEE_SAFE, "wrong fee Safe");
        require(feeSafe.code.length > 0, "Safe has no code");
        require(sentinelManager != address(0), "sentinel manager missing");
        require(bytes(baseURI).length != 0, "base URI missing");

        // Explicitly reject namespaces that must never be reused.
        bytes32 uriHash = keccak256(bytes(baseURI));
        require(
            uriHash != keccak256(bytes("https://clog.run/canary/")),
            "old canary URI forbidden"
        );
        require(
            uriHash != keccak256(bytes("https://clog.run/api/ticker-metadata/v2/")),
            "v2 URI already used"
        );
        require(
            uriHash != keccak256(bytes("https://clog.run/api/ticker-metadata/")),
            "unscoped URI forbidden"
        );

        vm.startBroadcast(deployer);

        eligibility = new EligibilityRegistry(
            deployer,
            CANARY_MIN_PROGRESS_BPS,
            CANARY_MIN_RESERVE,
            CANARY_REQUIRED_SECONDS
        );

        tickerNFT = new TickerNFT(
            "CLOG V4 V2 Canary Tickers",
            "CLOG-V2-CANARY",
            deployer,
            baseURI,
            feeSafe
        );

        registry = new TickerRegistryV4(
            address(eligibility),
            address(tickerNFT),
            feeSafe,
            VIRTUAL_ETH_SEED,
            BUFFER_BPS
        );

        bytes memory initCode = abi.encodePacked(
            type(ClogV4HookV2).creationCode,
            abi.encode(
                IPoolManager(POOL_MANAGER),
                address(registry),
                sentinelManager
            )
        );

        bytes32 initCodeHash = HookMinerV2.hashInitCode(initCode);

        (address predictedHook, bytes32 salt) =
            HookMinerV2.find(
                vm,
                CREATE2_DEPLOYER,
                initCodeHash,
                1_000_000
            );

        require(predictedHook.code.length == 0, "predicted hook already deployed");

        hook = new ClogV4HookV2{salt: salt}(
            IPoolManager(POOL_MANAGER),
            address(registry),
            sentinelManager
        );

        require(address(hook) == predictedHook, "CREATE2 hook mismatch");

        // Disposable canary: deployer acts as temporary round manager.
        // This canary is for launch/router/buy/sell verification, not production lottery wiring.
        rewardVault = new RewardVault(
            deployer,
            POOL_MANAGER,
            address(hook)
        );

        registry.setV4Infrastructure(
            POOL_MANAGER,
            address(hook),
            address(rewardVault)
        );

        tickerNFT.setRegistry(address(registry));
        eligibility.setRoundManager(deployer);

        vm.stopBroadcast();

        // -------- POST-DEPLOY INVARIANTS --------

        require(address(registry.poolManager()) == POOL_MANAGER, "wrong PoolManager");
        require(address(registry.hook()) == address(hook), "wrong hook");
        require(registry.rewardVault() == address(rewardVault), "wrong RewardVault");
        require(registry.multisig() == feeSafe, "wrong Registry Safe");

        require(hook.rewardVault() == address(rewardVault), "hook RewardVault mismatch");
        require(hook.sentinelManager() == sentinelManager, "wrong sentinel manager");

        require(
            uint160(address(hook)) & ALL_HOOK_MASK == REQUIRED_HOOK_MASK,
            "invalid V2 hook mask"
        );

        require(tickerNFT.tickerRegistry() == address(registry), "NFT registry mismatch");
        require(eligibility.roundManager() == deployer, "eligibility manager mismatch");

        require(registry.LAUNCH_PRICE() == 0.002 ether, "wrong launch price");
        require(registry.MULTISIG_LAUNCH_BPS() == 10_000, "wrong launch fee split");

        (address royaltyReceiver, uint256 royaltyAmount) =
            tickerNFT.royaltyInfo(1, 1 ether);

        require(royaltyReceiver == feeSafe, "wrong royalty recipient");
        require(royaltyAmount == 0.05 ether, "wrong royalty rate");

        console2.log("=== CLOG V4 V2 CANARY ===");
        console2.log("Deployer:", deployer);
        console2.log("Fee Safe:", feeSafe);
        console2.log("Sentinel manager:", sentinelManager);
        console2.log("PoolManager:", POOL_MANAGER);
        console2.log("EligibilityRegistry:", address(eligibility));
        console2.log("TickerNFT:", address(tickerNFT));
        console2.log("TickerRegistryV4:", address(registry));
        console2.log("ClogV4HookV2:", address(hook));
        console2.log("RewardVault:", address(rewardVault));
        console2.log("Predicted hook:", predictedHook);
        console2.log("Hook salt:", uint256(salt));
        console2.log("Hook mask:", uint256(uint160(address(hook)) & ALL_HOOK_MASK));
        console2.log("==========================");
    }
}
