// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRandomnessProvider
/// @notice Abstraction over the underlying randomness source (Chainlink VRF v2.5 on Arbitrum One,
///         relayed via CCIP, per the architecture doc) so RoundManager never depends on a specific
///         provider's request/callback shape directly. A provider implementation calls back into
///         RoundManager.onRandomnessReceived(requestId, randomWord) once fulfilled -- asynchronously,
///         on whatever timeline the underlying VRF/bridge actually delivers on. RoundManager places
///         no assumption on how long that takes (see architecture doc: this is why round close no
///         longer needs to pause trading -- settlement is fully decoupled from it).
interface IRandomnessProvider {
    /// @notice Requests one random word for `roundId`. Returns a provider-specific requestId that
    ///         will be passed back unchanged in the eventual callback.
    function requestRandomness(uint256 roundId) external returns (uint256 requestId);
}
