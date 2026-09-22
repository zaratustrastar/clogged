// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {ClogGenuineLiquidityHook} from "../src-v4/genuine/ClogGenuineLiquidityHook.sol";
import {ClogGenuineRegistry} from "../src-v4/genuine/ClogGenuineRegistry.sol";
import {ClogFourPositionMath} from "../src-v4/genuine/ClogFourPositionMath.sol";
import {TickerNFT} from "../src/TickerNFT.sol";
import {RewardVault} from "../src/RewardVault.sol";
import {EligibilityRegistry} from "../src/EligibilityRegistry.sol";

/// @title DeployGenuineCanary
/// @notice Deployment infrastructure ONLY for the genuine-liquidity architecture, frozen at
///         73c01bffee1bbe2491b21ebf4c792cab966f0500. This script deploys and wires; it does NOT
///         launch a ticker and does NOT trade. No private key appears anywhere - signing is done
///         by a named Foundry keystore passed on the command line.
///
///   SIMULATE (no broadcast, no keystore needed):
///     forge script script-v4/DeployGenuineCanary.s.sol:DeployGenuineCanary \
///       --profile v4 --use 0.8.26 --rpc-url https://rpc.mainnet.chain.robinhood.com -vvv
///
///   BROADCAST (later, only when approved):
///     forge script script-v4/DeployGenuineCanary.s.sol:DeployGenuineCanary \
///       --profile v4 --use 0.8.26 --rpc-url https://rpc.mainnet.chain.robinhood.com \
///       --account clog-deployer-robinhood --broadcast -vvv
contract DeployGenuineCanary is Script {
    // ── Robinhood mainnet, verified against the deployed chain ──
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    // CREATE2_FACTORY (0x4e59b44847b379578588920cA78FbF26c0B4956C) is inherited from
    // forge-std Base.sol and is byte-identical to the factory address supplied for Robinhood.
    address constant SAFE = 0x29DEf4F5429CAC1e364263C449A7aE791657d48F;

    // ── frozen economic parameters ──
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_BPS = 20_000;
    int24 constant TICK_SPACING = 1;
    uint256 constant LAUNCH_FEE = 0.002 ether;

    /// @dev BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | BEFORE_SWAP
    ///      | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP_RETURNS_DELTA
    uint160 constant REQUIRED_FLAGS = uint160(0x2ACC);
    uint160 constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    function run() external {
        address deployer = msg.sender;
        address multisig = vm.envOr("CLOG_MULTISIG", SAFE);
        address roundManager = vm.envOr("CLOG_ROUND_MANAGER", deployer);
        string memory baseURI = vm.envOr("CLOG_BASE_URI", string("https://clog.run/api/ticker-metadata/"));

        console2.log("== configuration ==");
        console2.log("  deployer       ", deployer);
        console2.log("  multisig       ", multisig);
        console2.log("  roundManager   ", roundManager);
        console2.log("  Safe (fee dest)", SAFE);
        console2.log("  PoolManager    ", POOL_MANAGER);
        console2.log("  CREATE2 factory", CREATE2_FACTORY);
        require(CREATE2_FACTORY == 0x4e59b44847b379578588920cA78FbF26c0B4956C, "unexpected CREATE2 factory");

        vm.startBroadcast();

        EligibilityRegistry eligibility = new EligibilityRegistry(deployer, 4, 0.03 ether, 600);
        TickerNFT nft = new TickerNFT("CLOG Tickers", "CLOG", deployer, baseURI, multisig);
        ClogFourPositionMath geometry = new ClogFourPositionMath(ClogFourPositionMath.HhMode.HI);

        ClogGenuineRegistry registry = new ClogGenuineRegistry(
            SAFE, address(nft), multisig, address(eligibility), VIRTUAL_ETH_SEED, BUFFER_BPS
        );

        // ── mine a CREATE2 salt so the hook address carries exactly REQUIRED_FLAGS ──
        bytes memory initCode = abi.encodePacked(
            type(ClogGenuineLiquidityHook).creationCode,
            abi.encode(IPoolManager(POOL_MANAGER), address(registry), geometry)
        );
        bytes32 initHash = keccak256(initCode);
        (address predicted, bytes32 salt) = _mine(initHash);
        console2.log("  mined hook addr", predicted);

        ClogGenuineLiquidityHook hook =
            ClogGenuineLiquidityHook(payable(_create2(salt, initCode)));
        require(address(hook) == predicted, "CREATE2 address mismatch");

        RewardVault vault = new RewardVault(roundManager, POOL_MANAGER, address(hook));

        registry.setV4Infrastructure(POOL_MANAGER, address(hook), address(vault));
        nft.setRegistry(address(registry));

        vm.stopBroadcast();

        _verify(eligibility, nft, geometry, registry, hook, vault);
        _verifyAccessControl(registry, hook, vault, deployer);

        console2.log("== deployed addresses ==");
        console2.log("  EligibilityRegistry   ", address(eligibility));
        console2.log("  TickerNFT             ", address(nft));
        console2.log("  ClogFourPositionMath  ", address(geometry));
        console2.log("  ClogGenuineRegistry   ", address(registry));
        console2.log("  ClogGenuineLiquidityHook", address(hook));
        console2.log("  RewardVault           ", address(vault));
        console2.log("");
        console2.log("NO ticker launched, NO trades performed. Launch fee stays", LAUNCH_FEE);
        console2.log("tickSpacing for launches:", int256(TICK_SPACING));
    }

    /// @dev Access control on the one-shot infrastructure wiring. Runs OUTSIDE the broadcast, so
    ///      the deliberate revert probe is a local simulation and is never sent.
    function _verifyAccessControl(
        ClogGenuineRegistry registry,
        ClogGenuineLiquidityHook hook,
        RewardVault vault,
        address deployer
    ) internal {
        require(registry.configurator() == deployer, "configurator != deployer");
        console2.log("  configurator == deployer  OK");

        require(address(registry.poolManager()) != address(0), "poolManager unconfigured");
        require(address(registry.hook()) != address(0), "hook unconfigured");
        require(registry.rewardVault() != address(0), "rewardVault unconfigured");
        console2.log("  infrastructure configured OK");

        // a second call must revert AlreadyConfigured - proves the wiring is one-shot
        (bool ok,) = address(registry).call(
            abi.encodeWithSelector(
                ClogGenuineRegistry.setV4Infrastructure.selector,
                POOL_MANAGER, address(hook), address(vault)
            )
        );
        require(!ok, "second setV4Infrastructure did NOT revert");
        console2.log("  re-configuration reverts  OK");
    }

    function _mine(bytes32 initHash) internal pure returns (address addr, bytes32 salt) {
        for (uint256 i = 0; i < 2_000_000; i++) {
            salt = bytes32(i);
            addr = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY, salt, initHash))))
            );
            if (uint160(addr) & ALL_HOOK_MASK == REQUIRED_FLAGS) return (addr, salt);
        }
        revert("no salt found");
    }

    function _create2(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        (bool ok, bytes memory ret) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        require(ok, "CREATE2 factory call failed");
        deployed = address(uint160(bytes20(ret)));
        require(deployed != address(0), "CREATE2 returned zero address");
    }

    function _verify(
        EligibilityRegistry eligibility,
        TickerNFT nft,
        ClogFourPositionMath geometry,
        ClogGenuineRegistry registry,
        ClogGenuineLiquidityHook hook,
        RewardVault vault
    ) internal view {
        console2.log("== verification ==");

        // hook permission mask
        uint160 flags = uint160(address(hook)) & ALL_HOOK_MASK;
        require(flags == REQUIRED_FLAGS, "hook flag mask wrong");
        console2.log("  hook flag mask 0x2ACC     OK");

        // runtime bytecode present everywhere
        require(address(eligibility).code.length > 0, "eligibility has no code");
        require(address(nft).code.length > 0, "nft has no code");
        require(address(geometry).code.length > 0, "geometry has no code");
        require(address(registry).code.length > 0, "registry has no code");
        require(address(hook).code.length > 0, "hook has no code");
        require(address(vault).code.length > 0, "vault has no code");
        require(POOL_MANAGER.code.length > 0, "PoolManager has no code on this chain");
        require(UNIVERSAL_ROUTER.code.length > 0, "UniversalRouter has no code");
        require(PERMIT2.code.length > 0, "Permit2 has no code");
        require(V4_QUOTER.code.length > 0, "V4Quoter has no code");
        console2.log("  runtime bytecode present  OK");

        // Registry <-> Hook <-> Vault <-> NFT wiring
        require(address(registry.poolManager()) == POOL_MANAGER, "registry.poolManager wrong");
        require(address(registry.hook()) == address(hook), "registry.hook wrong");
        require(registry.rewardVault() == address(vault), "registry.rewardVault wrong");
        require(registry.tickerNFT() == address(nft), "registry.tickerNFT wrong");
        require(address(hook.poolManager()) == POOL_MANAGER, "hook.poolManager wrong");
        require(hook.registry() == address(registry), "hook.registry wrong");
        require(hook.rewardVault() == address(vault), "hook.rewardVault wrong");
        require(address(hook.geometry()) == address(geometry), "hook.geometry wrong");
        require(nft.tickerRegistry() == address(registry), "nft.tickerRegistry wrong");
        console2.log("  registry/hook/vault/nft   OK");

        // Safe + frozen economics
        require(registry.safe() == SAFE, "Safe address wrong");
        require(registry.LAUNCH_PRICE() == LAUNCH_FEE, "launch fee != 0.002 ETH");
        require(registry.virtualEthSeed() == VIRTUAL_ETH_SEED, "virtual ETH seed != 9 ether");
        require(registry.bufferMultiplierBps() == BUFFER_BPS, "buffer != 20000");
        console2.log("  Safe + economics          OK");
        console2.log("  Safe                      ", registry.safe());
    }
}
