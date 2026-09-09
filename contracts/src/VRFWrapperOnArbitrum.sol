// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title VRFWrapperOnArbitrum
/// @notice Deployed on Arbitrum One (where Chainlink VRF v2.5 is natively supported). Receives a
///         randomness request from `ChainlinkRandomnessProvider` on Robinhood Chain via CCIP,
///         requests one random word from the real VRF v2.5 Coordinator, and relays the fulfilled
///         word back to Robinhood Chain via CCIP once Chainlink delivers it.
///
/// @dev This is the other half of the officially-documented "bring VRF to an unsupported chain"
///      pattern -- all actual randomness generation and cryptographic verification happens inside
///      `VRFConsumerBaseV2Plus`/the VRF Coordinator (official Chainlink contracts, imported
///      directly, never reimplemented). This contract's only job is the cross-chain
///      request/response bookkeeping: mapping a VRF requestId back to the CCIP request that asked
///      for it, and forwarding the result.
///
/// @dev DECOUPLED FULFILLMENT AND RELAY: receiving the VRF result (`fulfillRandomWords`) and
///      sending it onward via CCIP (`relayRandomness`) are two SEPARATE, independently-triggered
///      steps, not one atomic operation. `fulfillRandomWords` only stores the word and marks it
///      fulfilled -- it can never fail because of a CCIP-side problem, so a genuine, verified
///      random word can never be lost to an underfunded balance or a router hiccup. The relay
///      itself is a plain permissionless function, safe to retry indefinitely with the exact same
///      stored word until it succeeds.
///
/// @dev SUBSCRIPTION FUNDING is an operational requirement (LINK balance on the VRF subscription
///      this contract is registered as a consumer of), same as any other VRF integration -- not
///      something this contract manages itself. Separately, this contract's own ETH balance funds
///      the CCIP relay leg (see `relayRandomness`) -- if it runs low, relay attempts simply revert
///      and become retryable once topped up; the stored word is entirely unaffected.
contract VRFWrapperOnArbitrum is VRFConsumerBaseV2Plus, CCIPReceiver {
    uint64 public immutable robinhoodChainSelector;
    address public providerOnRobinhoodChain; // set once by governance after the provider is deployed

    bytes32 public keyHash;
    uint256 public subscriptionId;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint32 public constant CALLBACK_GAS_LIMIT = 1_000_000; // reassessed after decoupling relay from
        // fulfillment: fulfillRandomWords now does exactly 2 cold SLOADs (the vrfRequestId lookup,
        // the fulfilled-flag check), 1 cold SSTORE clearing that lookup, 2 cold SSTOREs setting
        // randomWord and fulfilled (separate storage slots -- randomWord takes a full slot,
        // fulfilled+relayed share a second), and one 2-word event -- roughly 55-60k gas by hand
        // count, comfortably under 100k with normal EVM/dispatch overhead included. 1,000,000
        // remains far more than sufficient (it was originally sized to cover a full CCIP send
        // in the same callback, which no longer happens here -- see `relayRandomness`, now a
        // separate, independently-gassed transaction). Left unchanged rather than shrunk: Chainlink
        // VRF subscriptions are charged for actual gas consumed, not the requested limit, so a
        // generously oversized limit costs nothing extra per request -- it only guards against
        // ever running out of gas. Guessing a smaller "right-sized" value would trade a real safety
        // margin for an optimization this fix doesn't need.
    uint32 public constant NUM_WORDS = 1;
    uint256 public constant DEST_CALLBACK_GAS_LIMIT = 300_000; // gas for the provider's _ccipReceive on Robinhood Chain

    /// @dev Keyed by ORIGINAL protocol requestId (not VRF's own internal request id, which exists
    ///      only transiently in `vrfRequestIdToOriginalRequestId` below and is discarded once
    ///      resolved). Once `fulfilled` is set, `randomWord` can never change -- see
    ///      `fulfillRandomWords`'s explicit guard against being called twice for the same request.
    struct FulfilledRequest {
        uint256 randomWord;
        bool fulfilled;
        bool relayed; // true once a CCIP send of this exact word has been successfully submitted --
            // pure cost hygiene (avoids paying for a redundant send); not a security boundary,
            // since the destination side (ChainlinkRandomnessProvider) independently rejects any
            // duplicate/replayed delivery on its own via `requestIdToRoundId` deletion-on-receipt.
    }

    mapping(uint256 => uint256) public vrfRequestIdToOriginalRequestId; // VRF's own id -> our protocol's requestId
    mapping(uint256 => FulfilledRequest) public fulfilledRequests; // protocol requestId -> stored result

    event ProviderUpdated(address indexed provider);
    event VrfConfigUpdated(bytes32 keyHash, uint256 subscriptionId);
    event RandomnessRequestedFromVRF(uint256 indexed originalRequestId, uint256 indexed vrfRequestId);
    event RandomnessFulfilled(uint256 indexed originalRequestId, uint256 randomWord);
    event RandomnessRelayedToRobinhoodChain(uint256 indexed originalRequestId, bytes32 ccipMessageId);

    constructor(
        address vrfCoordinator_,
        address ccipRouter_,
        uint64 robinhoodChainSelector_,
        bytes32 keyHash_,
        uint256 subscriptionId_
    ) VRFConsumerBaseV2Plus(vrfCoordinator_) CCIPReceiver(ccipRouter_) {
        robinhoodChainSelector = robinhoodChainSelector_;
        keyHash = keyHash_;
        subscriptionId = subscriptionId_;
    }

    receive() external payable {}

    /// @notice Set once the provider is deployed on Robinhood Chain. Owner-gated via
    ///         VRFConsumerBaseV2Plus's built-in ConfirmedOwner (in production, the owner is the
    ///         same Safe + timelock as everywhere else) -- ordinary operational configuration, not
    ///         a fund-custody-relevant value.
    function setProvider(address provider_) external onlyOwner {
        require(provider_ != address(0), "zero provider");
        providerOnRobinhoodChain = provider_;
        emit ProviderUpdated(provider_);
    }

    function setVrfConfig(bytes32 keyHash_, uint256 subscriptionId_) external onlyOwner {
        keyHash = keyHash_;
        subscriptionId = subscriptionId_;
        emit VrfConfigUpdated(keyHash_, subscriptionId_);
    }

    /// @dev Receives a randomness request forwarded from Robinhood Chain. Authenticates source
    ///      chain and sender before requesting anything from VRF.
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        require(message.sourceChainSelector == robinhoodChainSelector, "unexpected source chain");
        address sender = abi.decode(message.sender, (address));
        require(sender == providerOnRobinhoodChain, "unexpected sender");

        uint256 originalRequestId = abi.decode(message.data, (uint256));

        uint256 vrfRequestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        vrfRequestIdToOriginalRequestId[vrfRequestId] = originalRequestId;
        emit RandomnessRequestedFromVRF(originalRequestId, vrfRequestId);
    }

    /// @dev Called by the real VRF Coordinator once randomness is generated and verified.
    ///      STORES the result and marks it fulfilled -- does NOT attempt to relay it anywhere.
    ///      This is the entire point of the split: the VRF callback itself can never fail because
    ///      of a CCIP-side problem (insufficient balance, router issues, anything), so a real,
    ///      verified random word can never be lost to a funding hiccup. See `relayRandomness` for
    ///      the separate, independently-retryable delivery step.
    ///
    ///      `require(!f.fulfilled, ...)` makes it impossible for this to ever run twice for the
    ///      same original request and change what was stored -- the VRF Coordinator itself only
    ///      calls back once per request under normal operation, but this guard means even a
    ///      hypothetical duplicate callback could never overwrite an already-stored word.
    function fulfillRandomWords(uint256 vrfRequestId, uint256[] calldata randomWords) internal override {
        uint256 originalRequestId = vrfRequestIdToOriginalRequestId[vrfRequestId];
        require(originalRequestId != 0, "unknown vrf request");
        delete vrfRequestIdToOriginalRequestId[vrfRequestId];

        FulfilledRequest storage f = fulfilledRequests[originalRequestId];
        require(!f.fulfilled, "already fulfilled");
        f.randomWord = randomWords[0];
        f.fulfilled = true;
        emit RandomnessFulfilled(originalRequestId, randomWords[0]);
    }

    /// @notice Permissionless: relays an already-fulfilled, immutably stored random word to
    ///         Robinhood Chain via CCIP. Safe to call repeatedly if a prior attempt reverted (e.g.
    ///         insufficient ETH here for the CCIP fee at that time) -- always sends the exact same
    ///         stored word, since `randomWord` can never change after `fulfillRandomWords` sets it.
    ///         Not callable again once a send has succeeded (see `FulfilledRequest.relayed`).
    function relayRandomness(uint256 originalRequestId) external {
        FulfilledRequest storage f = fulfilledRequests[originalRequestId];
        require(f.fulfilled, "not fulfilled yet");
        require(!f.relayed, "already relayed");
        require(providerOnRobinhoodChain != address(0), "provider not set");

        // Marked before the external call (checks-effects-interactions): if `ccipSend` below
        // reverts (e.g. the balance check fails), this entire transaction reverts too, so
        // `relayed` rolls back along with everything else -- there is no way to end up with
        // `relayed == true` unless the send actually succeeded.
        f.relayed = true;

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(providerOnRobinhoodChain),
            data: abi.encode(originalRequestId, f.randomWord),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEST_CALLBACK_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });

        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(robinhoodChainSelector, message);
        require(address(this).balance >= fee, "insufficient balance for CCIP fee");

        bytes32 messageId = router.ccipSend{value: fee}(robinhoodChainSelector, message);
        emit RandomnessRelayedToRobinhoodChain(originalRequestId, messageId);
    }
}
