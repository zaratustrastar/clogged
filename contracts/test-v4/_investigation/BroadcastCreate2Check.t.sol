// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

contract TinyContract {
    uint256 public x = 42;
}

/// @notice ISOLATED investigation: confirms empirically whether vm.startBroadcast + a salted
///         `new` expression routes the deployment through the well-known deterministic
///         deployment proxy (0x4e59b44847b379578588920cA78FbF26c0B4956C) rather than treating
///         the broadcast address itself as the CREATE2 deployer.
contract BroadcastCreate2Investigation is Test {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function test_broadcastSaltedNew_usesFactoryOrEoaAsDeployer() public {
        address broadcaster = makeAddr("broadcaster");
        vm.deal(broadcaster, 10 ether);
        bytes32 salt = keccak256("test-salt");
        bytes32 initCodeHash = keccak256(type(TinyContract).creationCode);

        address predictedViaFactory = _computeCreate2Address(salt, initCodeHash, CREATE2_DEPLOYER);
        address predictedViaEoa = _computeCreate2Address(salt, initCodeHash, broadcaster);

        emit log_string("=== CREATE2_DEPLOYER code check ===");
        emit log_named_uint("  CREATE2_DEPLOYER.code.length", CREATE2_DEPLOYER.code.length);

        vm.startBroadcast(broadcaster);
        TinyContract deployed = new TinyContract{salt: salt}();
        vm.stopBroadcast();

        emit log_string("=== Results ===");
        emit log_named_address("  actual deployed address", address(deployed));
        emit log_named_address("  predicted via FACTORY as deployer", predictedViaFactory);
        emit log_named_address("  predicted via EOA (broadcaster) as deployer", predictedViaEoa);

        bool matchesFactory = (address(deployed) == predictedViaFactory);
        bool matchesEoa = (address(deployed) == predictedViaEoa);
        emit log_named_string("  matches FACTORY-based prediction?", matchesFactory ? "YES" : "NO");
        emit log_named_string("  matches EOA-based prediction?", matchesEoa ? "YES" : "NO");
    }
}
