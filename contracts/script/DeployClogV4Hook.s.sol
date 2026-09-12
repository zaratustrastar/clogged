// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {ClogV4Hook} from "../src/ClogV4Hook.sol";
import {TickerRegistry} from "../src/TickerRegistry.sol";

/// @title DeployClogV4Hook
/// @notice Deploys the single, universal ClogV4Hook via CREATE2 through the standard, well-known
///         CREATE2 deployer proxy (0x4e59b44847b379578588920cA78FbF26c0B4956C - the same proxy
///         Foundry's own `salt:` deployment syntax uses, and the address HookMiner's own doc
///         comment specifies for a real forge script deployment, not the deployer EOA). Mines a
///         salt so the deployed address encodes exactly the required permission bits
///         (BEFORE_SWAP_FLAG | BEFORE_SWAP_RETURNS_DELTA_FLAG - beforeSwap only; this hook never
///         touches liquidity or donate callbacks, and never needs afterSwap since the full
///         economic result is expressed entirely through beforeSwap's own BeforeSwapDelta), then
///         verifies the deployed address's actual bits match, rather than trusting the mining
///         step alone. Does not initialize any pools or register any markets - see
///         RegisterClogV4Market.s.sol for the permissionless, per-token follow-up step.
contract DeployClogV4Hook is Script {
    // The standard, well-known CREATE2 deployer proxy used by Foundry's own salt-based
    // deployment mechanism and documented directly in HookMiner's own comments.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 constant REQUIRED_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    function run() external returns (ClogV4Hook hook) {
        address poolManagerAddress = vm.envAddress("V4_POOL_MANAGER_ADDRESS");
        address tickerRegistryAddress = vm.envAddress("TICKER_REGISTRY_ADDRESS");

        bytes memory constructorArgs =
            abi.encode(IPoolManager(poolManagerAddress), TickerRegistry(tickerRegistryAddress));
        (address predictedAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, REQUIRED_FLAGS, type(ClogV4Hook).creationCode, constructorArgs);

        vm.startBroadcast();
        hook = new ClogV4Hook{salt: salt}(IPoolManager(poolManagerAddress), TickerRegistry(tickerRegistryAddress));
        vm.stopBroadcast();

        require(address(hook) == predictedAddress, "deployed address does not match mined address");
        _verifyPermissionBits(address(hook));

        console2.log("=== ClogV4Hook Deployment ===");
        console2.log("Hook address:", address(hook));
        console2.log("PoolManager:", poolManagerAddress);
        console2.log("TickerRegistry:", tickerRegistryAddress);
        console2.log("Salt:", uint256(salt));
    }

    /// @notice Verifies the deployed address's actual permission bits match exactly what was
    ///         intended - not a re-statement of the mining step's own assumption, an independent
    ///         check against the real address using the same bit-flag logic PoolManager itself
    ///         uses (Hooks.hasPermission), confirmed directly against the vendored source.
    function _verifyPermissionBits(address hookAddress) internal pure {
        IHooks hookAsInterface = IHooks(hookAddress);
        require(uint160(hookAddress) & Hooks.BEFORE_SWAP_FLAG != 0, "missing BEFORE_SWAP_FLAG");
        require(
            uint160(hookAddress) & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0, "missing BEFORE_SWAP_RETURNS_DELTA_FLAG"
        );
        // Explicitly confirm every OTHER flag is unset - this hook must never accidentally gain
        // permission for liquidity/donate/afterSwap callbacks it doesn't implement.
        uint160 unexpectedBits = uint160(hookAddress) & Hooks.ALL_HOOK_MASK & ~REQUIRED_FLAGS;
        require(unexpectedBits == 0, "unexpected extra permission bits set");
        hookAsInterface; // silence unused-variable warning; kept for readability of intent above
    }
}
