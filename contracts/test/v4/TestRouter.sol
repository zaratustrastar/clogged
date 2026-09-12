// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4Router} from "@uniswap/v4-periphery/src/V4Router.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Minimal concrete router built on the REAL, official V4Router/BaseActionsRouter
/// framework for testing ClogV4Hook - not a hand-rolled stand-in for the router layer itself.
contract TestRouter is V4Router {
    address private _currentSender;

    constructor(IPoolManager _poolManager) V4Router(_poolManager) {}

    function execute(bytes calldata actions, bytes[] calldata params) external payable {
        _currentSender = msg.sender;
        poolManager.unlock(abi.encode(actions, params));
        _currentSender = address(0);
    }

    function msgSender() public view override returns (address) {
        return _currentSender;
    }

    function _pay(Currency token, address payer, uint256 amount) internal override {
        (bool ok, bytes memory data) = Currency.unwrap(token)
            .call(abi.encodeWithSignature("transferFrom(address,address,uint256)", payer, address(poolManager), amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "ERC20 pay failed");
    }
}
