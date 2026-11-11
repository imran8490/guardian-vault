// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

import { HelloOrigin } from "../src/HelloOrigin.sol";
import { HelloCallback } from "../src/HelloCallback.sol";
import { HelloReactive } from "../src/HelloReactive.sol";

/// Step 1 (Base Sepolia): deploy the origin contract.
///   forge script script/Deploy.s.sol:DeployOrigin --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
contract DeployOrigin is Script {
    function run() external {
        vm.startBroadcast();
        HelloOrigin origin = new HelloOrigin();
        vm.stopBroadcast();
        console.log("HelloOrigin:", address(origin));
    }
}

/// Step 2 (Reactive Lasna): deploy the reactive contract. Needs ORIGIN_ADDRESS.
///   forge script script/Deploy.s.sol:DeployReactive --rpc-url $LASNA_RPC --account $ACCOUNT --broadcast
/// The constructor value (lREACT) pays for reactive transactions. Default 1 lREACT.
contract DeployReactive is Script {
    function run() external {
        address origin = vm.envAddress("ORIGIN_ADDRESS");
        uint256 originChainId = vm.envOr("ORIGIN_CHAIN_ID", uint256(84532));
        uint256 destChainId = vm.envOr("DEST_CHAIN_ID", uint256(84532));
        uint256 fund = vm.envOr("REACTIVE_FUND_WEI", uint256(1 ether));

        vm.startBroadcast();
        HelloReactive reactive = new HelloReactive{ value: fund }(originChainId, origin, destChainId);
        vm.stopBroadcast();
        console.log("HelloReactive:", address(reactive));
    }
}

/// Step 3 (Base Sepolia): deploy the callback receiver. Needs REACTIVE_ADDRESS.
///   forge script script/Deploy.s.sol:DeployCallback --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
/// Callbacks are billed to this contract in ETH, so it is funded at deploy (default 0.005 ETH).
contract DeployCallback is Script {
    // Base Sepolia callback proxy (from the Reactive docs, origins-and-destinations).
    address constant BASE_SEPOLIA_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external {
        address reactive = vm.envAddress("REACTIVE_ADDRESS");
        address proxy = vm.envOr("CALLBACK_PROXY", BASE_SEPOLIA_PROXY);
        uint256 fund = vm.envOr("CALLBACK_FUND_WEI", uint256(0.005 ether));

        vm.startBroadcast();
        HelloCallback cb = new HelloCallback{ value: fund }(IPayable(payable(proxy)), reactive);
        vm.stopBroadcast();
        console.log("HelloCallback:", address(cb));
    }
}

/// Step 4 (Reactive Lasna): tell the reactive contract where to send callbacks. Needs
/// REACTIVE_ADDRESS and CALLBACK_ADDRESS. Can only be set once, by the deployer.
///   forge script script/Deploy.s.sol:LinkRecipient --rpc-url $LASNA_RPC --account $ACCOUNT --broadcast
contract LinkRecipient is Script {
    function run() external {
        HelloReactive reactive = HelloReactive(payable(vm.envAddress("REACTIVE_ADDRESS")));
        address cb = vm.envAddress("CALLBACK_ADDRESS");

        vm.startBroadcast();
        reactive.setCallbackRecipient(cb);
        vm.stopBroadcast();
        console.log("Recipient linked:", cb);
    }
}

/// Step 5 (Base Sepolia): fire the event that starts the loop. Needs ORIGIN_ADDRESS.
///   forge script script/Deploy.s.sol:PingOrigin --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
contract PingOrigin is Script {
    function run() external {
        HelloOrigin origin = HelloOrigin(vm.envAddress("ORIGIN_ADDRESS"));
        uint256 value = vm.envOr("PING_VALUE", uint256(42));

        vm.startBroadcast();
        uint256 id = origin.ping(value);
        vm.stopBroadcast();
        console.log("Ping sent, id:", id);
    }
}
