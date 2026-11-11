// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";

import { HelloOrigin } from "../src/HelloOrigin.sol";
import { HelloCallback } from "../src/HelloCallback.sol";
import { HelloReactive } from "../src/HelloReactive.sol";

/// @dev Minimal stand-in for the Reactive system contract. We only need to record what the
///      reactive contract asks of it.
contract MockSystem {
    struct Sub {
        uint256 chainId;
        address contractAddr;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    Sub[] public subs;
    ISystemContract.CallbackConfiguration_V_1_0 public lastCallback;
    uint256 public callbackCount;

    function subscribe(uint256 c, address a, uint256 t0, uint256 t1, uint256 t2, uint256 t3)
        external
    {
        subs.push(Sub(c, a, t0, t1, t2, t3));
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_)
        external
    {
        lastCallback = config_;
        unchecked {
            ++callbackCount;
        }
    }

    function subsLength() external view returns (uint256) {
        return subs.length;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }
}

contract HelloLoopTest is Test {
    address constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 constant ORIGIN_CHAIN = 84532; // Base Sepolia
    uint256 constant DEST_CHAIN = 84532;
    address constant PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585; // Base Sepolia callback proxy

    MockSystem sys;
    HelloOrigin origin;
    HelloReactive reactive;
    HelloCallback callbackC;

    address alice = makeAddr("alice");

    function setUp() public {
        // Put the mock system contract at the real system address.
        vm.etch(SYSTEM_ADDR, address(new MockSystem()).code);
        sys = MockSystem(SYSTEM_ADDR);

        origin = new HelloOrigin();
        reactive = new HelloReactive(ORIGIN_CHAIN, address(origin), DEST_CHAIN);
        callbackC = new HelloCallback(IPayable(payable(PROXY)), address(reactive));
        reactive.setCallbackRecipient(address(callbackC));
    }

    // ---------- subscription ----------

    function test_constructorSubscribesToPing() public view {
        assertEq(sys.subsLength(), 1);
        (uint256 c, address a, uint256 t0, uint256 t1, uint256 t2, uint256 t3) = sys.subs(0);
        assertEq(c, ORIGIN_CHAIN);
        assertEq(a, address(origin));
        assertEq(t0, uint256(keccak256("Ping(address,uint256,uint256)")));
        assertEq(t1, uint256(0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad));
        assertEq(t2, t1);
        assertEq(t3, t1);
    }

    function test_pingTopicMatchesRealEvent() public {
        vm.recordLogs();
        vm.prank(alice);
        origin.ping(42);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(uint256(logs[0].topics[0]), reactive.PING_TOPIC_0());
        assertEq(address(uint160(uint256(logs[0].topics[1]))), alice);
        assertEq(uint256(logs[0].topics[2]), 1);
        assertEq(abi.decode(logs[0].data, (uint256)), 42);
    }

    // ---------- react() ----------

    function _log(uint256 id, address pinger, uint256 value)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: ORIGIN_CHAIN,
            contractAddress: address(origin),
            topic0: reactive.PING_TOPIC_0(),
            topic1: uint256(uint160(pinger)),
            topic2: id,
            topic3: 0,
            data: abi.encode(value),
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function test_reactRequestsCallbackWithExpectedPayload() public {
        IReactive.LogRecord memory l = _log(7, alice, 1234);
        vm.prank(SYSTEM_ADDR);
        reactive.react(l);

        assertEq(sys.callbackCount(), 1);
        (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) =
            sys.lastCallback();
        assertEq(chainId, DEST_CHAIN);
        assertEq(recipient, address(callbackC));
        assertEq(gasLimit, reactive.CALLBACK_GAS_LIMIT());
        assertEq(
            payload,
            abi.encodeWithSignature(
                "onPong(address,uint256,address,uint256)", address(0), uint256(7), alice, uint256(1234)
            )
        );
        assertEq(reactive.reactCount(), 1);
    }

    function test_reactOnlySystem() public {
        IReactive.LogRecord memory l = _log(1, alice, 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, alice, SYSTEM_ADDR)
        );
        reactive.react(l);
    }

    function test_reactIgnoresOtherEvents() public {
        IReactive.LogRecord memory l = _log(1, alice, 1);
        l.contractAddress = address(0xBEEF);
        vm.prank(SYSTEM_ADDR);
        reactive.react(l);
        assertEq(sys.callbackCount(), 0);

        l = _log(1, alice, 1);
        l.topic0 = 123;
        vm.prank(SYSTEM_ADDR);
        reactive.react(l);
        assertEq(sys.callbackCount(), 0);
    }

    function test_setRecipientOnce_andOnlyOwner() public {
        vm.expectRevert(HelloReactive.RecipientAlreadySet.selector);
        reactive.setCallbackRecipient(address(1));

        HelloReactive r2 = new HelloReactive(ORIGIN_CHAIN, address(origin), DEST_CHAIN);
        vm.prank(alice);
        vm.expectRevert(HelloReactive.NotOwner.selector);
        r2.setCallbackRecipient(address(1));
    }

    function test_reactRevertsIfRecipientNotSet() public {
        HelloReactive r2 = new HelloReactive(ORIGIN_CHAIN, address(origin), DEST_CHAIN);
        IReactive.LogRecord memory l = _log(1, alice, 1);
        vm.prank(SYSTEM_ADDR);
        vm.expectRevert(HelloReactive.RecipientNotSet.selector);
        r2.react(l);
    }

    // ---------- callback side ----------

    function test_callbackAcceptsProxyWithRightSender() public {
        vm.prank(PROXY);
        callbackC.onPong(address(reactive), 7, alice, 1234);
        assertEq(callbackC.lastId(), 7);
        assertEq(callbackC.lastValue(), 1234);
        assertEq(callbackC.lastPinger(), alice);
        assertEq(callbackC.pongCount(), 1);
    }

    function test_callbackRejectsNonProxy() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, alice, PROXY));
        callbackC.onPong(address(reactive), 7, alice, 1234);
    }

    function test_callbackRejectsWrongReactiveSender() public {
        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), address(reactive)
            )
        );
        callbackC.onPong(address(0xBAD), 7, alice, 1234);
    }
}
