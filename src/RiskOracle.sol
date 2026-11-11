// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

/// @title RiskOracle
/// @notice The on-chain door through which the off-chain AI's verdict enters the system.
///         Only the AI service's signer wallet can publish. The reactive contract subscribes to
///         `RiskUpdated`, so without a fresh AI verdict nothing downstream moves: the model is
///         part of the running loop, not decoration.
contract RiskOracle {
    address public owner;
    address public signer;

    uint256 public epoch;
    uint8 public latestScore;
    uint256 public latestTimestamp;
    bytes32 public latestReasonHash;

    /// @param epoch Monotonic counter of verdicts (topic1) so consumers can dedupe/order.
    /// @param score 0 (calm) .. 100 (severe).
    /// @param timestamp block.timestamp at publish.
    /// @param reasonHash keccak256 of the model's explanation (full text kept off-chain/in repo logs).
    event RiskUpdated(uint256 indexed epoch, uint8 score, uint256 timestamp, bytes32 reasonHash);
    event SignerChanged(address indexed oldSigner, address indexed newSigner);

    error NotOwner();
    error NotSigner();
    error ScoreOutOfRange(uint8 score);
    error ZeroAddress();

    constructor(address signer_) {
        if (signer_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        signer = signer_;
        emit SignerChanged(address(0), signer_);
    }

    function setSigner(address newSigner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newSigner == address(0)) revert ZeroAddress();
        emit SignerChanged(signer, newSigner);
        signer = newSigner;
    }

    function publishRisk(uint8 score, bytes32 reasonHash) external returns (uint256 newEpoch) {
        if (msg.sender != signer) revert NotSigner();
        if (score > 100) revert ScoreOutOfRange(score);

        newEpoch = ++epoch;
        latestScore = score;
        latestTimestamp = block.timestamp;
        latestReasonHash = reasonHash;
        emit RiskUpdated(newEpoch, score, block.timestamp, reasonHash);
    }
}
