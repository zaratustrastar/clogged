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
/// @dev SUBSCRIPTION FUNDING is an operational requirement (LINK balance on the VRF subscription
///      this contract is registered as a consumer of), same as any other VRF integration -- not
///      something this contract manages itself.
contract VRFWrapperOnArbitrum is VRFConsumerBaseV2Plus, CCIPReceiver {
    uint64 public immutable robinhoodChainSelector;
    address public providerOnRobinhoodChain; // set once by governance after the provider is deployed

    bytes32 public keyHash;
    uint256 public subscriptionId;
    uint16 public constant REQUEST_CONFIRMATIONS = 3;
    uint32 public constant CALLBACK_GAS_LIMIT = 1_000_000; // generous: fulfillRandomWords itself
        // triggers a full CCIP send back to Robinhood Chain (which, on the LOCAL mock used for
        // testing, synchronously re-enters the provider's ccipReceive), so this needs headroom
        // well beyond simple bookkeeping.
    uint32 public constant NUM_WORDS = 1;
    uint256 public constant DEST_CALLBACK_GAS_LIMIT = 300_000; // gas for the provider's _ccipReceive on Robinhood Chain

    mapping(uint256 => uint256) public vrfRequestIdToOriginalRequestId; // VRF's own id -> our protocol's requestId

    event ProviderUpdated(address indexed provider);
    event VrfConfigUpdated(bytes32 keyHash, uint256 subscriptionId);
    event RandomnessRequestedFromVRF(uint256 indexed originalRequestId, uint256 indexed vrfRequestId);
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

    /// @dev Called by the real VRF Coordinator once randomness is generated and verified. Relays
    ///      the result back to Robinhood Chain via CCIP.
    function fulfillRandomWords(uint256 vrfRequestId, uint256[] calldata randomWords) internal override {
        uint256 originalRequestId = vrfRequestIdToOriginalRequestId[vrfRequestId];
        delete vrfRequestIdToOriginalRequestId[vrfRequestId];

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(providerOnRobinhoodChain),
            data: abi.encode(originalRequestId, randomWords[0]),
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
