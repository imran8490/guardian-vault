// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

/// @title HelloOrigin
/// @notice Week 1 smoke test. Lives on the origin chain (Base Sepolia).
///         Anyone can call `ping()`; it emits the event the reactive contract watches.
contract HelloOrigin {
    /// @dev topic0 = keccak256("Ping(address,uint256,uint256)")
    event Ping(address indexed sender, uint256 indexed id, uint256 value);

    uint256 public nextId;

    function ping(uint256 value) external returns (uint256 id) {
        id = ++nextId;
        emit Ping(msg.sender, id, value);
    }
}
