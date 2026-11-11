// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @title GuardianReactive
/// @notice Lives on Reactive Lasna. Watches the RiskOracle's `RiskUpdated` events (published by the
///         AI service) on the origin chain and decides, on its own, whether the vault must move.
///
/// The decision logic is deliberately here, not in the AI and not in the vault:
///   - hysteresis: de-risk at score >= HIGH, re-risk only at score <= LOW (LOW < HIGH), so a score
///     wobbling around one threshold cannot make the vault flip-flop;
///   - cooldown: no second action within COOLDOWN seconds of the last one (block.timestamp, never
///     block counts: Base blocks are ~200 ms);
///   - staleness: a verdict older than MAX_AGE seconds is ignored;
///   - replay protection: only epochs newer than the last seen are considered.
contract GuardianReactive is AbstractReactive {
    // keccak256("RiskUpdated(uint256,uint8,uint256,bytes32)")
    uint256 public constant RISK_TOPIC_0 =
        uint256(keccak256("RiskUpdated(uint256,uint8,uint256,bytes32)"));
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    uint256 public immutable ORACLE_CHAIN_ID;
    address public immutable ORACLE;
    uint256 public immutable DESTINATION_CHAIN_ID;
    address public immutable OWNER;

    uint8 public immutable HIGH_THRESHOLD;
    uint8 public immutable LOW_THRESHOLD;
    uint256 public immutable COOLDOWN;
    uint256 public immutable MAX_AGE;

    address public vault;
    bool public riskOff;
    uint256 public lastEpoch;
    uint256 public lastActionAt;

    uint256 public reactCount;
    uint256 public actionCount;

    event ActionRequested(uint256 indexed epoch, uint8 score, bool deRisk);
    /// @dev reason: 1 stale epoch, 2 verdict too old, 3 cooldown, 4 no action needed
    event Skipped(uint256 indexed epoch, uint8 score, uint8 reason);
    event RiskStateOverridden(bool riskOff);

    error NotOwner();
    error VaultAlreadySet();
    error VaultNotSet();
    error BadConfig();

    constructor(
        uint256 oracleChainId_,
        address oracle_,
        uint256 destinationChainId_,
        uint8 high_,
        uint8 low_,
        uint256 cooldown_,
        uint256 maxAge_
    ) payable {
        if (low_ >= high_ || high_ > 100 || maxAge_ == 0) revert BadConfig();
        OWNER = msg.sender;
        ORACLE_CHAIN_ID = oracleChainId_;
        ORACLE = oracle_;
        DESTINATION_CHAIN_ID = destinationChainId_;
        HIGH_THRESHOLD = high_;
        LOW_THRESHOLD = low_;
        COOLDOWN = cooldown_;
        MAX_AGE = maxAge_;

        SYSTEM.subscribe(
            oracleChainId_,
            oracle_,
            RISK_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /// @notice One-time link to the vault (the vault needs this contract's address at deploy, so
    ///         the reverse link cannot be a constructor argument).
    function setVault(address vault_) external {
        if (msg.sender != OWNER) revert NotOwner();
        if (vault != address(0)) revert VaultAlreadySet();
        vault = vault_;
    }

    /// @notice Recovery lever: if a callback ever fails on the destination chain this contract's
    ///         belief about the vault's state can drift; the owner can realign it.
    function overrideRiskState(bool riskOff_) external {
        if (msg.sender != OWNER) revert NotOwner();
        riskOff = riskOff_;
        emit RiskStateOverridden(riskOff_);
    }

    function react(LogRecord calldata log_) external override onlySystem {
        address vault_ = vault;
        if (vault_ == address(0)) revert VaultNotSet();

        if (
            log_.chainId != ORACLE_CHAIN_ID || log_.contractAddress != ORACLE
                || log_.topic0 != RISK_TOPIC_0
        ) {
            return;
        }

        unchecked {
            ++reactCount;
        }

        uint256 epoch = log_.topic1;
        (uint8 score, uint256 publishedAt,) = abi.decode(log_.data, (uint8, uint256, bytes32));

        if (epoch <= lastEpoch) {
            emit Skipped(epoch, score, 1);
            return;
        }
        lastEpoch = epoch;

        if (block.timestamp > publishedAt + MAX_AGE) {
            emit Skipped(epoch, score, 2);
            return;
        }

        bool wantDeRisk = !riskOff && score >= HIGH_THRESHOLD;
        bool wantReRisk = riskOff && score <= LOW_THRESHOLD;
        if (!wantDeRisk && !wantReRisk) {
            emit Skipped(epoch, score, 4);
            return;
        }

        if (lastActionAt != 0 && block.timestamp < lastActionAt + COOLDOWN) {
            emit Skipped(epoch, score, 3);
            return;
        }

        riskOff = wantDeRisk;
        lastActionAt = block.timestamp;
        unchecked {
            ++actionCount;
        }
        emit ActionRequested(epoch, score, wantDeRisk);

        // First argument is a placeholder; Reactive Network overwrites it with this contract's address.
        bytes memory payload = abi.encodeWithSignature(
            wantDeRisk ? "deRisk(address,uint256,uint256)" : "reRisk(address,uint256,uint256)",
            address(0),
            epoch,
            uint256(score)
        );

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: DESTINATION_CHAIN_ID,
                recipient: vault_,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
    }
}
