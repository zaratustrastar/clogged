// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRandomnessProvider} from "../../src/IRandomnessProvider.sol";

interface IRoundManagerCallback {
    function onRandomnessReceived(uint256 requestId, uint256 randomWord) external;
}

/// @notice Test-only stand-in for the real Chainlink VRF v2.5 (Arbitrum One) + CCIP relay
///         described in the architecture doc. Requests are recorded; the test calls `fulfill`
///         manually to simulate the asynchronous VRF/CCIP round trip completing.
contract MockRandomnessProvider is IRandomnessProvider {
    address public roundManager;
    uint256 public nextRequestId = 1;
    mapping(uint256 => uint256) public requestToRound;
    bool public shouldRevert; // simulates an underfunded/unavailable provider

    function setRoundManager(address rm) external {
        roundManager = rm;
    }

    /// @notice Test-only failure toggle -- simulates the provider being temporarily underfunded or
    ///         CCIP being unavailable, without needing the real cross-chain adapter stack.
    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function requestRandomness(uint256 roundId) external override returns (uint256 requestId) {
        require(!shouldRevert, "MockRandomnessProvider: simulated failure");
        requestId = nextRequestId++;
        requestToRound[requestId] = roundId;
    }

    function fulfill(uint256 requestId, uint256 randomWord) external {
        IRoundManagerCallback(roundManager).onRandomnessReceived(requestId, randomWord);
    }
}
