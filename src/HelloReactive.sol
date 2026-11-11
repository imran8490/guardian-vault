// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @title HelloReactive
/// @notice Week 1 smoke test. Lives on Reactive Lasna (chain id 5318007).
///         Watches `Ping` on the origin chain and asks Reactive Network to call
///         `HelloCallback.onPong(...)` on the destination chain.
/// @dev Omni fork: there is no RVM any more. One deployment, standard Solidity, and the
///      constructor can call SYSTEM.subscribe() directly. No dual-deploy / vm-detection code.
contract HelloReactive is AbstractReactive {
    // keccak256("Ping(address,uint256,uint256)")
    uint256 public constant PING_TOPIC_0 = uint256(keccak256("Ping(address,uint256,uint256)"));
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    uint256 public immutable ORIGIN_CHAIN_ID;
    address public immutable ORIGIN_CONTRACT;
    uint256 public immutable DESTINATION_CHAIN_ID;

    /// @notice Set once by the owner after HelloCallback is deployed (callback needs this reactive
    ///         contract's address, and this contract needs the callback's address: chicken-and-egg).
    address public callbackRecipient;
    address public immutable OWNER;

    uint256 public reactCount;

    error NotOwner();
    error RecipientAlreadySet();
    error RecipientNotSet();

    event Reacted(uint256 indexed id, address indexed pinger, uint256 value);

    constructor(uint256 originChainId_, address originContract_, uint256 destinationChainId_)
        payable
    {
        OWNER = msg.sender;
        ORIGIN_CHAIN_ID = originChainId_;
        ORIGIN_CONTRACT = originContract_;
        DESTINATION_CHAIN_ID = destinationChainId_;

        SYSTEM.subscribe(
            originChainId_,
            originContract_,
            PING_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    function setCallbackRecipient(address recipient_) external {
        if (msg.sender != OWNER) revert NotOwner();
        if (callbackRecipient != address(0)) revert RecipientAlreadySet();
        callbackRecipient = recipient_;
    }

    /// @notice Called by the system contract for every matching log.
    function react(LogRecord calldata log_) external override onlySystem {
        address recipient = callbackRecipient;
        if (recipient == address(0)) revert RecipientNotSet();

        // Only act on the exact event we subscribed to.
        if (
            log_.chainId != ORIGIN_CHAIN_ID || log_.contractAddress != ORIGIN_CONTRACT
                || log_.topic0 != PING_TOPIC_0
        ) {
            return;
        }

        address pinger = address(uint160(log_.topic1));
        uint256 id = log_.topic2;
        uint256 value = abi.decode(log_.data, (uint256));

        unchecked {
            ++reactCount;
        }
        emit Reacted(id, pinger, value);

        // First argument is a placeholder: Reactive Network overwrites its first 160 bits
        // with this reactive contract's address.
        bytes memory payload =
            abi.encodeWithSignature("onPong(address,uint256,address,uint256)", address(0), id, pinger, value);

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: DESTINATION_CHAIN_ID,
                recipient: recipient,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
    }
}
