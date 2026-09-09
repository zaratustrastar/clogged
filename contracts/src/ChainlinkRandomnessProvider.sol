// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {IRandomnessProvider} from "./IRandomnessProvider.sol";

interface IRoundManagerCallback {
    function onRandomnessReceived(uint256 requestId, uint256 randomWord) external;
}

/// @title ChainlinkRandomnessProvider
/// @notice Deployed on Robinhood Chain. Implements `IRandomnessProvider` for RoundManager by
///         relaying randomness requests to `VRFWrapperOnArbitrum` (deployed on Arbitrum One, where
///         Chainlink VRF v2.5 is natively available) via Chainlink CCIP -- the officially
///         documented pattern for bringing VRF to a chain that doesn't have it natively (Chainlink
///         publishes this exact "CrossChainVRFConsumer + CrossChainVRFWrapper" shape; CCIP is used
///         here as the messaging layer instead of a chain-specific alternative, since CCIP is what
///         Robinhood Chain actually has live from mainnet launch).
///
/// @dev THIS CONTRACT DOES NOT REPRODUCE RANDOMNESS LOGIC. It only does protocol-specific mapping:
///      roundId -> CCIP message -> requestId, and authenticates the one message type it accepts
///      back (source chain must be Arbitrum One, sender must be the known wrapper address). All
///      cryptographic randomness generation and verification happens inside Chainlink's own VRF
///      Coordinator on Arbitrum One; this contract never sees or checks a VRF proof itself.
///
/// @dev FUNDING: CCIP messages cost a fee, paid here in native gas token. This contract holds its
///      own ETH balance for that purpose (topped up via `receive()`) rather than requiring
///      RoundManager's permissionless `closeRoundAndOpenNext` caller to also supply ETH -- keeping
///      round-closing free of any payment requirement. Keeping this funded is an operational
///      responsibility, same as keeping a VRF subscription funded with LINK.
///
/// @dev LIVENESS VS. CORRECTNESS: if this contract runs out of ETH, or CCIP/VRF is temporarily
///      unavailable, `requestRandomness` simply reverts -- the round is left unresolved
///      (RoundManager's `drawSkipped` stays false, `randomnessRequested` stays false) until
///      someone tops this contract up and retries -- no admin can ever manufacture a winner
///      instead. A temporarily broken randomness path costs liveness, never fund safety or
///      fairness.
contract ChainlinkRandomnessProvider is IRandomnessProvider, CCIPReceiver {
    address public immutable deployer; // authorized to call setRoundManager exactly once
    address public roundManager; // address(0) until setRoundManager is called; permanent afterward
    uint64 public immutable arbitrumChainSelector;
    address public wrapperOnArbitrum; // set once by governance after the wrapper is deployed
    address public governance;

    uint256 public constant DEST_CALLBACK_GAS_LIMIT = 300_000; // gas for the wrapper's _ccipReceive

    mapping(uint256 => uint256) public requestIdToRoundId;
    uint256 public nextLocalRequestId = 1;

    event WrapperUpdated(address indexed wrapper);
    event RoundManagerInitialized(address indexed roundManager);
    event RandomnessRequestSent(uint256 indexed roundId, uint256 indexed requestId, bytes32 ccipMessageId);
    event RandomnessReceivedFromArbitrum(uint256 indexed requestId, uint256 randomWord);

    modifier onlyRoundManager() {
        require(msg.sender == roundManager, "not round manager");
        _;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "not governance");
        _;
    }

    constructor(address router_, uint64 arbitrumChainSelector_, address governance_, address deployer_)
        CCIPReceiver(router_)
    {
        require(governance_ != address(0) && deployer_ != address(0), "zero address");
        deployer = deployer_;
        arbitrumChainSelector = arbitrumChainSelector_;
        governance = governance_;
    }

    /// @notice One-time initialization: sets RoundManager permanently. Callable exactly once,
    ///         only by `deployer`. No path exists to call this again, by anyone -- not deployer,
    ///         not governance. Removes the CREATE-nonce address prediction previously needed to
    ///         resolve the circular dependency with RoundManager: this contract is now deployed
    ///         before RoundManager, RoundManager takes this contract's real, already-known address
    ///         directly in its own constructor, and this setter wires the relationship back
    ///         afterward.
    function setRoundManager(address roundManager_) external {
        require(msg.sender == deployer, "not deployer");
        require(roundManager == address(0), "already initialized");
        require(roundManager_ != address(0), "zero round manager");
        roundManager = roundManager_;
        emit RoundManagerInitialized(roundManager_);
    }

    receive() external payable {}

    /// @notice Set once the wrapper is deployed on Arbitrum One. Governance-gated (behind the
    ///         timelock in production), updatable if the wrapper ever needs to migrate -- unlike
    ///         the one-time launch-time initializations elsewhere in this codebase, this is
    ///         ordinary operational configuration, not a fund-custody-relevant value.
    function setWrapper(address wrapper_) external onlyGovernance {
        require(wrapper_ != address(0), "zero wrapper");
        wrapperOnArbitrum = wrapper_;
        emit WrapperUpdated(wrapper_);
    }

    /// @inheritdoc IRandomnessProvider
    function requestRandomness(uint256 roundId) external onlyRoundManager returns (uint256 requestId) {
        require(wrapperOnArbitrum != address(0), "wrapper not set");
        requestId = nextLocalRequestId++;
        requestIdToRoundId[requestId] = roundId;

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(wrapperOnArbitrum),
            data: abi.encode(requestId),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0), // pay in native gas token
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: DEST_CALLBACK_GAS_LIMIT, allowOutOfOrderExecution: true})
            )
        });

        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(arbitrumChainSelector, message);
        require(address(this).balance >= fee, "insufficient balance for CCIP fee");

        bytes32 messageId = router.ccipSend{value: fee}(arbitrumChainSelector, message);
        emit RandomnessRequestSent(roundId, requestId, messageId);
    }

    /// @dev Receives the fulfilled random word back from the wrapper on Arbitrum One. Authenticates
    ///      both the source chain and the specific sender address before trusting anything in the
    ///      payload -- CCIP delivers the message, but this contract still decides whether to
    ///      believe its contents.
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        require(message.sourceChainSelector == arbitrumChainSelector, "unexpected source chain");
        address sender = abi.decode(message.sender, (address));
        require(sender == wrapperOnArbitrum, "unexpected sender");

        (uint256 requestId, uint256 randomWord) = abi.decode(message.data, (uint256, uint256));
        uint256 roundId = requestIdToRoundId[requestId];
        require(roundId != 0, "unknown request");
        delete requestIdToRoundId[requestId]; // replay protection: this request is now consumed

        emit RandomnessReceivedFromArbitrum(requestId, randomWord);
        IRoundManagerCallback(roundManager).onRandomnessReceived(requestId, randomWord);
    }
}
