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

    function setRoundManager(address rm) external {
        roundManager = rm;
    }

    function requestRandomness(uint256 roundId) external override returns (uint256 requestId) {
        requestId = nextRequestId++;
        requestToRound[requestId] = roundId;
    }

    function fulfill(uint256 requestId, uint256 randomWord) external {
        IRoundManagerCallback(roundManager).onRandomnessReceived(requestId, randomWord);
    }
}
