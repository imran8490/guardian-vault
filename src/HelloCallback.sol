// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// @title HelloCallback
/// @notice Week 1 smoke test. Lives on the destination chain (Base Sepolia).
///         Receives the callback that Reactive Network sends after it sees a `Ping`.
/// @dev Two guards, always both:
///      - onlyServiceProvider: msg.sender must be the callback proxy of this chain.
///      - onlyCallbackSender: the injected first argument must be OUR reactive contract.
///      The callback is billed to THIS contract in the destination chain's native token (ETH),
///      so fund it (constructor value or a plain transfer).
contract HelloCallback is AbstractCallback {
    event Pong(address indexed reactive, uint256 indexed id, address indexed pinger, uint256 value);

    uint256 public lastId;
    uint256 public lastValue;
    address public lastPinger;
    uint256 public lastReceivedAt;
    uint256 public pongCount;

    constructor(IPayable callbackProxy_, address reactiveContract_)
        payable
        AbstractCallback(callbackProxy_, reactiveContract_)
    { }

    /// @param reactive_ Overwritten by Reactive Network with the address of the requesting reactive contract.
    function onPong(address reactive_, uint256 id, address pinger, uint256 value)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        lastId = id;
        lastValue = value;
        lastPinger = pinger;
        lastReceivedAt = block.timestamp;
        unchecked {
            ++pongCount;
        }
        emit Pong(reactive_, id, pinger, value);
    }

    /// @notice Anyone may trigger settlement of outstanding callback debt from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }
}
