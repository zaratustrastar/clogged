// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ChainlinkRandomnessProvider} from "../src/ChainlinkRandomnessProvider.sol";
import {VRFWrapperOnArbitrum} from "../src/VRFWrapperOnArbitrum.sol";

/// @title WireCrossChain
/// @notice Run once both DeployRobinhoodChain.s.sol and DeployArbitrumWrapper.s.sol have completed
///         and their addresses are known. Both remaining wiring calls
///         (ChainlinkRandomnessProvider.setWrapper on Robinhood Chain,
///         VRFWrapperOnArbitrum.setProvider on Arbitrum One) are governance-gated on their
///         respective chains, so this script does not execute anything itself -- it only logs the
///         exact target + calldata for whichever ONE of them applies to the chain it's currently
///         pointed at, ready to queue through the relevant timelock/Safe.
///
/// @dev CHAIN-AWARE BY CONSTRUCTION, NOT BY CONFIGURED CHAIN ID: `ChainlinkRandomnessProvider`
///      only ever exists on Robinhood Chain; `VRFWrapperOnArbitrum` only ever exists on Arbitrum
///      One. The two addresses can therefore never both have real bytecode on the same chain in
///      an actual deployment -- run this script once per chain (via --rpc-url), and it detects
///      which side it's on by checking which of the two addresses actually has code THERE, then
///      logs only the ONE governance action relevant to that chain. It deliberately does not take
///      an expected-chain-id parameter to decide this: which address has local bytecode is the
///      ground truth this script actually cares about, and stays correct even if a chain id is
///      ever reused or misconfigured elsewhere.
///
/// @dev If EITHER both addresses have code, or NEITHER does, this reverts rather than guessing --
///      "both have code" can only happen from a copy-paste address error or a same-EVM test setup
///      (never a real two-chain deployment), and "neither has code" almost always means the wrong
///      --rpc-url or an address from a deployment that hasn't happened yet.
contract WireCrossChain is Script {
    function run() external view {
        address providerAddr = vm.envAddress("CHAINLINK_RANDOMNESS_PROVIDER");
        address wrapperAddr = vm.envAddress("VRF_WRAPPER_ON_ARBITRUM");

        bool providerHasLocalCode = providerAddr.code.length > 0;
        bool wrapperHasLocalCode = wrapperAddr.code.length > 0;

        require(
            !(providerHasLocalCode && wrapperHasLocalCode),
            "WireCrossChain: both addresses have local bytecode -- provider and wrapper can never both live on the same chain in a real deployment; check --rpc-url"
        );
        require(
            providerHasLocalCode || wrapperHasLocalCode,
            "WireCrossChain: neither address has local bytecode on this chain -- check --rpc-url and that both deployments have already been broadcast"
        );

        console2.log("=== Cross-chain wiring: required governance action for this chain ===");
        console2.log("chain id:", block.chainid);

        if (providerHasLocalCode) {
            console2.log("Detected: this is Robinhood Chain (ChainlinkRandomnessProvider has local bytecode here).");
            console2.log("Queue through the timelock (proposer: the Safe):");
            console2.log("  target:", providerAddr);
            console2.log("  calldata:");
            console2.logBytes(abi.encodeCall(ChainlinkRandomnessProvider.setWrapper, (wrapperAddr)));
            console2.log("(VRF_WRAPPER_ON_ARBITRUM is the remote Arbitrum One address -- it is not");
            console2.log("expected to have code on this chain, and none was checked for it.)");
        } else {
            console2.log("Detected: this is Arbitrum One (VRFWrapperOnArbitrum has local bytecode here).");
            console2.log("Queue via wrapper's owner (must have already called acceptOwnership()):");
            console2.log("  target:", wrapperAddr);
            console2.log("  calldata:");
            console2.logBytes(abi.encodeCall(VRFWrapperOnArbitrum.setProvider, (providerAddr)));
            console2.log("(CHAINLINK_RANDOMNESS_PROVIDER is the remote Robinhood Chain address -- it is");
            console2.log("not expected to have code on this chain, and none was checked for it.)");
        }

        console2.log("");
        console2.log("Run this script again pointed at the OTHER chain to get that side's action.");
        console2.log("The protocol cannot resolve any draw until BOTH have executed.");
    }
}
