// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";

import { MockToken } from "../src/MockToken.sol";
import { MockPool } from "../src/MockPool.sol";
import { RiskOracle } from "../src/RiskOracle.sol";
import { GuardianVault } from "../src/GuardianVault.sol";
import { GuardianReactive } from "../src/GuardianReactive.sol";

/// @dev Stand-in for the Reactive system contract: records subscriptions and callback requests.
contract MockSystemG {
    struct Sub {
        uint256 chainId;
        address contractAddr;
        uint256 topic0;
    }

    Sub[] public subs;
    ISystemContract.CallbackConfiguration_V_1_0 public lastCallback;
    uint256 public callbackCount;

    function subscribe(uint256 c, address a, uint256 t0, uint256, uint256, uint256) external {
        subs.push(Sub(c, a, t0));
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

abstract contract GuardianBase is Test {
    address constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address constant PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    uint256 constant BASE = 84532;
    uint256 constant T0 = 1_000_000;

    uint8 constant HIGH = 70;
    uint8 constant LOW = 30;
    uint256 constant COOLDOWN = 60;
    uint256 constant MAX_AGE = 600;

    MockSystemG sys;
    MockToken vol;
    MockToken stable;
    MockPool pool;
    RiskOracle oracle;
    GuardianReactive reactive;
    GuardianVault vault;

    address ai = makeAddr("ai");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public virtual {
        vm.warp(T0);
        vm.etch(SYSTEM_ADDR, address(new MockSystemG()).code);
        sys = MockSystemG(SYSTEM_ADDR);

        vol = new MockToken("Volatile", "VOL");
        stable = new MockToken("Stable", "STBL");
        pool = new MockPool(vol, stable);

        vol.mint(address(this), 1_000e18);
        stable.mint(address(this), 1_000e18);
        vol.approve(address(pool), type(uint256).max);
        stable.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1_000e18, 1_000e18);

        oracle = new RiskOracle(ai);
        reactive = new GuardianReactive(BASE, address(oracle), BASE, HIGH, LOW, COOLDOWN, MAX_AGE);
        vault = new GuardianVault(
            IPayable(payable(PROXY)), address(reactive), vol, stable, pool, oracle, HIGH, LOW, MAX_AGE
        );
        reactive.setVault(address(vault));

        _deposit(alice, 100e18);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 minted) {
        vol.mint(who, amount);
        vm.startPrank(who);
        vol.approve(address(vault), type(uint256).max);
        minted = vault.deposit(amount);
        vm.stopPrank();
    }

    function _log(uint256 epoch, uint8 score, uint256 publishedAt)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: BASE,
            contractAddress: address(oracle),
            topic0: reactive.RISK_TOPIC_0(),
            topic1: epoch,
            topic2: 0,
            topic3: 0,
            data: abi.encode(score, publishedAt, bytes32(uint256(0xabc))),
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _react(uint256 epoch, uint8 score) internal {
        _reactAt(epoch, score, block.timestamp);
    }

    function _reactAt(uint256 epoch, uint8 score, uint256 publishedAt) internal {
        IReactive.LogRecord memory l = _log(epoch, score, publishedAt);
        vm.prank(SYSTEM_ADDR);
        reactive.react(l);
    }

    /// @dev The AI signer publishes a verdict on the oracle; returns its epoch.
    function _verdict(uint8 score) internal returns (uint256 epoch) {
        vm.prank(ai);
        epoch = oracle.publishRisk(score, keccak256(abi.encode("test verdict", score)));
    }

    function _callbackAsProxy(uint256 epoch, bool deRisk_, uint256 score) internal {
        vm.prank(PROXY);
        if (deRisk_) vault.deRisk(address(reactive), epoch, score);
        else vault.reRisk(address(reactive), epoch, score);
    }
}

// =============================================================================== RiskOracle

contract RiskOracleTest is GuardianBase {
    function test_onlySignerCanPublish() public {
        vm.prank(alice);
        vm.expectRevert(RiskOracle.NotSigner.selector);
        oracle.publishRisk(50, bytes32(0));
    }

    function test_publishEmitsAndStores() public {
        vm.expectEmit(true, false, false, true);
        emit RiskOracle.RiskUpdated(1, 85, T0, bytes32(uint256(7)));
        vm.prank(ai);
        uint256 e = oracle.publishRisk(85, bytes32(uint256(7)));
        assertEq(e, 1);
        assertEq(oracle.latestScore(), 85);
        assertEq(oracle.latestTimestamp(), T0);

        vm.prank(ai);
        assertEq(oracle.publishRisk(10, bytes32(0)), 2);
    }

    function test_scoreAbove100Reverts() public {
        vm.prank(ai);
        vm.expectRevert(abi.encodeWithSelector(RiskOracle.ScoreOutOfRange.selector, uint8(101)));
        oracle.publishRisk(101, bytes32(0));
    }

    function test_riskTopicMatchesRealEvent() public {
        vm.recordLogs();
        vm.prank(ai);
        oracle.publishRisk(55, bytes32(uint256(1)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(uint256(logs[0].topics[0]), reactive.RISK_TOPIC_0());
        assertEq(uint256(logs[0].topics[1]), 1);
        (uint8 score, uint256 ts, bytes32 h) = abi.decode(logs[0].data, (uint8, uint256, bytes32));
        assertEq(score, 55);
        assertEq(ts, T0);
        assertEq(h, bytes32(uint256(1)));
    }

    function test_setSignerOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(RiskOracle.NotOwner.selector);
        oracle.setSigner(alice);

        oracle.setSigner(bob);
        vm.prank(ai);
        vm.expectRevert(RiskOracle.NotSigner.selector);
        oracle.publishRisk(1, bytes32(0));
        vm.prank(bob);
        oracle.publishRisk(1, bytes32(0));
    }
}

// =============================================================================== MockPool

contract MockPoolTest is GuardianBase {
    function test_startsAtParity() public view {
        assertEq(pool.priceE18(), 1e18);
    }

    function test_bigSellCrashesPrice() public {
        vol.mint(bob, 500e18);
        vm.startPrank(bob);
        vol.approve(address(pool), type(uint256).max);
        uint256 out = pool.swap(true, 500e18, 0, bob);
        vm.stopPrank();
        assertGt(out, 300e18);
        assertLt(pool.priceE18(), 0.5e18);
        assertEq(stable.balanceOf(bob), out);
    }

    function test_swapEmitsPostSwapPrice() public {
        vol.mint(bob, 100e18);
        vm.startPrank(bob);
        vol.approve(address(pool), type(uint256).max);
        vm.recordLogs();
        pool.swap(true, 100e18, 0, bob);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // last log is the pool's Swap event
        Vm.Log memory sw = logs[logs.length - 1];
        assertEq(sw.emitter, address(pool));
        (bool dir,,, uint256 price) = abi.decode(sw.data, (bool, uint256, uint256, uint256));
        assertTrue(dir);
        assertEq(price, pool.priceE18());
    }

    function test_minOutEnforced() public {
        vol.mint(bob, 100e18);
        vm.startPrank(bob);
        vol.approve(address(pool), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockPool.InsufficientOutput.selector, pool.getAmountOut(true, 100e18), 100e18
            )
        );
        pool.swap(true, 100e18, 100e18, bob);
        vm.stopPrank();
    }
}

// =============================================================================== GuardianVault

contract GuardianVaultTest is GuardianBase {
    function test_depositWithdrawRoundTrip() public {
        assertEq(vault.shares(alice), 100e18);
        vm.prank(alice);
        (uint256 v, uint256 s) = vault.withdraw(100e18);
        assertEq(v, 100e18);
        assertEq(s, 0);
        assertEq(vol.balanceOf(alice), 100e18);
        assertEq(vault.totalShares(), 0);
    }

    function test_proRataBetweenUsers() public {
        _deposit(bob, 100e18);
        assertEq(vault.shares(bob), 100e18);
        vm.prank(bob);
        (uint256 v,) = vault.withdraw(50e18);
        assertEq(v, 50e18);
        (uint256 vh,) = vault.holdings();
        assertEq(vh, 150e18);
    }

    function test_withdrawMoreThanSharesReverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(GuardianVault.InsufficientShares.selector, 100e18, 101e18)
        );
        vault.withdraw(101e18);
    }

    function test_zeroAmountsRevert() public {
        vm.prank(alice);
        vm.expectRevert(GuardianVault.ZeroAmount.selector);
        vault.deposit(0);
        vm.prank(alice);
        vm.expectRevert(GuardianVault.ZeroAmount.selector);
        vault.withdraw(0);
    }

    // ---- callback authentication

    function test_deRiskRejectsNonProxy() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, alice, PROXY));
        vault.deRisk(address(reactive), 1, 90);
    }

    function test_deRiskRejectsWrongReactiveSender() public {
        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), address(reactive)
            )
        );
        vault.deRisk(address(0xBAD), 1, 90);
    }

    function test_reRiskRejectsNonProxyAndWrongSender() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, alice, PROXY));
        vault.reRisk(address(reactive), 1, 10);

        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractCallback.CallbackNotAuthorized.selector, address(0xBAD), address(reactive)
            )
        );
        vault.reRisk(address(0xBAD), 1, 10);
    }

    // ---- behaviour

    function test_deRiskSellsAllVolForStable() public {
        _verdict(90);
        _callbackAsProxy(1, true, 90);
        (uint256 v, uint256 s) = vault.holdings();
        assertEq(v, 0);
        assertGt(s, 85e18);
        assertTrue(vault.riskOff());
        assertEq(vault.lastActedEpoch(), 1);
    }

    function test_withdrawWhileRiskOffPaysStable() public {
        _verdict(90);
        _callbackAsProxy(1, true, 90);
        vm.prank(alice);
        (uint256 v, uint256 s) = vault.withdraw(100e18);
        assertEq(v, 0);
        assertGt(s, 85e18);
        assertEq(stable.balanceOf(alice), s);
    }

    function test_depositsPausedWhileRiskOff() public {
        _verdict(90);
        _callbackAsProxy(1, true, 90);
        vol.mint(bob, 10e18);
        vm.startPrank(bob);
        vol.approve(address(vault), type(uint256).max);
        vm.expectRevert(GuardianVault.DepositsPausedWhileRiskOff.selector);
        vault.deposit(10e18);
        vm.stopPrank();
    }

    function test_reRiskBuysBack() public {
        _verdict(90);
        _callbackAsProxy(1, true, 90);
        _verdict(10);
        _callbackAsProxy(2, false, 10);
        (uint256 v, uint256 s) = vault.holdings();
        assertGt(v, 90e18);
        assertEq(s, 0);
        assertFalse(vault.riskOff());
    }

    function test_duplicateAndStaleCallbacksAreIgnored() public {
        _verdict(90);
        _callbackAsProxy(1, true, 90);
        _verdict(95);
        (uint256 v1, uint256 s1) = vault.holdings();

        // newer epoch but already risk-off -> reason 2
        vm.expectEmit(true, false, false, true);
        emit GuardianVault.CallbackIgnored(2, 2);
        _callbackAsProxy(2, true, 95);

        // replay of an old epoch -> reason 1
        vm.expectEmit(true, false, false, true);
        emit GuardianVault.CallbackIgnored(1, 1);
        _callbackAsProxy(1, true, 95);

        (uint256 v2, uint256 s2) = vault.holdings();
        assertEq(v1, v2);
        assertEq(s1, s2);
    }

    function test_reRiskWhenNotRiskOffIsIgnored() public {
        vm.expectEmit(true, false, false, true);
        emit GuardianVault.CallbackIgnored(1, 2);
        _callbackAsProxy(1, false, 10);
        (uint256 v,) = vault.holdings();
        assertEq(v, 100e18);
    }

    function test_slippageGuardBlocksBadTrade() public {
        _verdict(90);
        _deposit(bob, 300e18); // vault now 400 VOL against a 1000/1000 pool: ~29% impact
        uint256 expectedOut = pool.getAmountOut(true, 400e18);
        uint256 minOut = (400e18 * (10_000 - vault.maxSlippageBps())) / 10_000;
        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(MockPool.InsufficientOutput.selector, expectedOut, minOut)
        );
        vault.deRisk(address(reactive), 1, 90);
        // state untouched, users can still leave
        assertFalse(vault.riskOff());
        vm.prank(bob);
        vault.withdraw(300e18);
    }

    function test_ownerCanLoosenSlippage_butCapped() public {
        vm.prank(alice);
        vm.expectRevert(GuardianVault.NotOwner.selector);
        vault.setMaxSlippageBps(2_000);

        vm.expectRevert(abi.encodeWithSelector(GuardianVault.SlippageTooHigh.selector, 5_001));
        vault.setMaxSlippageBps(5_001);

        vault.setMaxSlippageBps(4_000);
        _verdict(90);
        _deposit(bob, 300e18);
        vm.prank(PROXY);
        vault.deRisk(address(reactive), 1, 90); // now passes
        assertTrue(vault.riskOff());
    }

    // ---- independent verdict check: the vault reads the oracle itself (wrong / unjustified AI verdicts)

    function test_wrongVerdict_calmOracleBlocksDeRisk() public {
        // AI says calm (20), but a (buggy/compromised) reactive layer asks to de-risk with score 95
        uint256 e = _verdict(20);
        vm.expectEmit(true, false, false, true);
        emit GuardianVault.CallbackRejected(e, 1, 20);
        _callbackAsProxy(e, true, 95);
        assertFalse(vault.riskOff());
        (uint256 v,) = vault.holdings();
        assertEq(v, 100e18);
        assertEq(vault.lastActedEpoch(), 0);
    }

    function test_wrongVerdict_middleBandBlocksBothDirections() public {
        uint256 e = _verdict(50); // between LOW and HIGH: justifies neither move
        vm.expectEmit(true, false, false, true);
        emit GuardianVault.CallbackRejected(e, 1, 50);
        _callbackAsProxy(e, true, 90);
        assertFalse(vault.riskOff());

        _verdict(90);
        _callbackAsProxy(2, true, 90);
        assertTrue(vault.riskOff());

        uint256 e3 = _verdict(50);
        vm.expectEmit(true, false, false, true);
        emit GuardianVault.CallbackRejected(e3, 1, 50);
        _callbackAsProxy(e3, false, 10);
        assertTrue(vault.riskOff()); // stayed in stable
    }

    function test_wrongVerdict_thresholdsAreInclusive() public {
        uint256 e = _verdict(HIGH);
        _callbackAsProxy(e, true, HIGH);
        assertTrue(vault.riskOff());
        uint256 e2 = _verdict(LOW);
        _callbackAsProxy(e2, false, LOW);
        assertFalse(vault.riskOff());
    }

    function test_wrongVerdict_highOracleBlocksReRisk() public {
        uint256 e1 = _verdict(90);
        _callbackAsProxy(e1, true, 90);
        uint256 e2 = _verdict(85); // still dangerous
        vm.expectEmit(true, false, false, true);
        emit GuardianVault.CallbackRejected(e2, 1, 85);
        _callbackAsProxy(e2, false, 5); // forged "all clear"
        assertTrue(vault.riskOff());
        assertEq(vault.lastActedEpoch(), e1);
    }

    function test_supersededVerdict_cannotSellVault() public {
        uint256 e1 = _verdict(90); // danger...
        _verdict(10); // ...but a calmer verdict landed before the callback arrived
        vm.expectEmit(true, false, false, true);
        emit GuardianVault.CallbackRejected(e1, 1, 10);
        _callbackAsProxy(e1, true, 90);
        assertFalse(vault.riskOff());
    }

    function test_staleOracleVerdict_isRejected() public {
        uint256 e = _verdict(90);
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectEmit(true, false, false, true);
        emit GuardianVault.CallbackRejected(e, 2, 90);
        _callbackAsProxy(e, true, 90);
        assertFalse(vault.riskOff());
    }

    function test_verdictExactlyMaxAge_stillAccepted() public {
        uint256 e = _verdict(90);
        vm.warp(block.timestamp + MAX_AGE);
        _callbackAsProxy(e, true, 90);
        assertTrue(vault.riskOff());
    }

    function test_futureEpoch_isRejected() public {
        _verdict(90); // oracle epoch = 1
        vm.expectEmit(true, false, false, true);
        emit GuardianVault.CallbackRejected(7, 3, 90);
        _callbackAsProxy(7, true, 90);
        assertFalse(vault.riskOff());
    }

    function test_noVerdictEverPublished_rejects() public {
        // oracle epoch 0, score 0: nothing justifies selling
        vm.expectEmit(true, false, false, true);
        emit GuardianVault.CallbackRejected(1, 3, 0);
        _callbackAsProxy(1, true, 95);
        assertFalse(vault.riskOff());
    }

    function test_rejectedCallbackDoesNotConsumeEpoch() public {
        uint256 e1 = _verdict(20);
        _callbackAsProxy(e1, true, 95); // rejected
        uint256 e2 = _verdict(88);
        _callbackAsProxy(e2, true, 88); // later honest verdict still works
        assertTrue(vault.riskOff());
        assertEq(vault.lastActedEpoch(), e2);
    }

    function test_vaultBadConfigReverts() public {
        IPayable p = IPayable(payable(PROXY));
        vm.expectRevert(GuardianVault.BadConfig.selector);
        new GuardianVault(p, address(reactive), vol, stable, pool, oracle, 30, 70, MAX_AGE);
        vm.expectRevert(GuardianVault.BadConfig.selector);
        new GuardianVault(p, address(reactive), vol, stable, pool, oracle, HIGH, LOW, 0);
        vm.expectRevert(GuardianVault.BadConfig.selector);
        new GuardianVault(
            p, address(reactive), vol, stable, pool, RiskOracle(address(0)), HIGH, LOW, MAX_AGE
        );
    }

    function test_userCanAlwaysWithdraw_evenIfReactiveNeverActs() public {
        vm.prank(alice);
        vault.withdraw(100e18);
        assertEq(vol.balanceOf(alice), 100e18);
    }
}

// =============================================================================== GuardianReactive

contract GuardianReactiveTest is GuardianBase {
    function test_constructorSubscribesToRiskUpdated() public view {
        // subs[0] is the one created by `reactive` (the only reactive contract created in setUp)
        (uint256 c, address a, uint256 t0) = sys.subs(0);
        assertEq(c, BASE);
        assertEq(a, address(oracle));
        assertEq(t0, uint256(keccak256("RiskUpdated(uint256,uint8,uint256,bytes32)")));
    }

    function test_badConfigReverts() public {
        vm.expectRevert(GuardianReactive.BadConfig.selector);
        new GuardianReactive(BASE, address(oracle), BASE, 30, 30, 60, 600); // low == high
        vm.expectRevert(GuardianReactive.BadConfig.selector);
        new GuardianReactive(BASE, address(oracle), BASE, 101, 30, 60, 600);
        vm.expectRevert(GuardianReactive.BadConfig.selector);
        new GuardianReactive(BASE, address(oracle), BASE, 70, 30, 60, 0);
    }

    function test_highScoreRequestsDeRiskCallback() public {
        _react(1, 90);

        assertEq(sys.callbackCount(), 1);
        (uint256 chainId, address recipient, uint64 gas, bytes memory payload) = sys.lastCallback();
        assertEq(chainId, BASE);
        assertEq(recipient, address(vault));
        assertEq(gas, reactive.CALLBACK_GAS_LIMIT());
        assertEq(
            payload,
            abi.encodeWithSignature(
                "deRisk(address,uint256,uint256)", address(0), uint256(1), uint256(90)
            )
        );
        assertTrue(reactive.riskOff());
        assertEq(reactive.actionCount(), 1);
        assertEq(reactive.lastEpoch(), 1);
    }

    function test_thresholdIsInclusive() public {
        _react(1, HIGH - 1);
        assertEq(sys.callbackCount(), 0);
        _react(2, HIGH);
        assertEq(sys.callbackCount(), 1);
    }

    function test_belowThresholdDoesNothing() public {
        vm.expectEmit(true, false, false, true);
        emit GuardianReactive.Skipped(1, 40, 4);
        _react(1, 40);
        assertEq(sys.callbackCount(), 0);
        assertFalse(reactive.riskOff());
    }

    function test_hysteresis_middleBandDoesNotFlipBack() public {
        _react(1, 80);
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.expectEmit(true, false, false, true);
        emit GuardianReactive.Skipped(2, 50, 4); // between LOW and HIGH
        _react(2, 50);
        assertEq(sys.callbackCount(), 1);
        assertTrue(reactive.riskOff());

        _react(3, LOW); // inclusive low threshold
        assertEq(sys.callbackCount(), 2);
        assertFalse(reactive.riskOff());
        (,,, bytes memory payload) = sys.lastCallback();
        assertEq(
            payload,
            abi.encodeWithSignature(
                "reRisk(address,uint256,uint256)", address(0), uint256(3), uint256(LOW)
            )
        );
    }

    function test_cooldownBlocksQuickFlipThenAllowsLater() public {
        _react(1, 90);

        vm.warp(block.timestamp + 10);
        vm.expectEmit(true, false, false, true);
        emit GuardianReactive.Skipped(2, 10, 3);
        _react(2, 10);
        assertEq(sys.callbackCount(), 1);
        assertTrue(reactive.riskOff());

        vm.warp(block.timestamp + COOLDOWN);
        _react(3, 10);
        assertEq(sys.callbackCount(), 2);
        assertFalse(reactive.riskOff());
    }

    function test_staleVerdictIgnored() public {
        uint256 old = block.timestamp - MAX_AGE - 1;
        vm.expectEmit(true, false, false, true);
        emit GuardianReactive.Skipped(1, 95, 2);
        _reactAt(1, 95, old);
        assertEq(sys.callbackCount(), 0);
        assertFalse(reactive.riskOff());
    }

    function test_verdictExactlyMaxAgeStillValid() public {
        _reactAt(1, 95, block.timestamp - MAX_AGE);
        assertEq(sys.callbackCount(), 1);
    }

    function test_replayedEpochIgnored() public {
        _react(1, 90);
        vm.expectEmit(true, false, false, true);
        emit GuardianReactive.Skipped(1, 90, 1);
        _react(1, 90);
        assertEq(sys.callbackCount(), 1);
        assertEq(reactive.actionCount(), 1);
    }

    function test_ignoresOtherContractsAndTopics() public {
        IReactive.LogRecord memory l = _log(1, 95, block.timestamp);
        l.contractAddress = address(0xBEEF);
        vm.prank(SYSTEM_ADDR);
        reactive.react(l);

        l = _log(1, 95, block.timestamp);
        l.topic0 = 123;
        vm.prank(SYSTEM_ADDR);
        reactive.react(l);

        l = _log(1, 95, block.timestamp);
        l.chainId = 1;
        vm.prank(SYSTEM_ADDR);
        reactive.react(l);

        assertEq(sys.callbackCount(), 0);
        assertEq(reactive.reactCount(), 0);
    }

    function test_reactOnlySystem() public {
        IReactive.LogRecord memory l = _log(1, 95, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, alice, SYSTEM_ADDR)
        );
        reactive.react(l);
    }

    function test_reactRevertsIfVaultNotSet() public {
        GuardianReactive r2 =
            new GuardianReactive(BASE, address(oracle), BASE, HIGH, LOW, COOLDOWN, MAX_AGE);
        IReactive.LogRecord memory l = _log(1, 95, block.timestamp);
        vm.prank(SYSTEM_ADDR);
        vm.expectRevert(GuardianReactive.VaultNotSet.selector);
        r2.react(l);
    }

    function test_setVaultOnceAndOnlyOwner() public {
        vm.expectRevert(GuardianReactive.VaultAlreadySet.selector);
        reactive.setVault(address(1));

        GuardianReactive r2 =
            new GuardianReactive(BASE, address(oracle), BASE, HIGH, LOW, COOLDOWN, MAX_AGE);
        vm.prank(alice);
        vm.expectRevert(GuardianReactive.NotOwner.selector);
        r2.setVault(address(1));
    }

    function test_ownerCanRealignState() public {
        _react(1, 90);
        assertTrue(reactive.riskOff());

        vm.prank(alice);
        vm.expectRevert(GuardianReactive.NotOwner.selector);
        reactive.overrideRiskState(false);

        reactive.overrideRiskState(false);
        assertFalse(reactive.riskOff());
    }
}

// =============================================================================== end to end

/// @dev Walks the whole loop with real contracts, faking only the Reactive Network hop:
///      crash -> oracle event -> reactive.react -> callback payload -> vault (via proxy).
contract GuardianLoopTest is GuardianBase {
    function decodeTail(bytes calldata data) external pure returns (address, uint256, uint256) {
        return abi.decode(data[4:], (address, uint256, uint256));
    }

    function test_fullLoop_crashToDeRiskToRecovery() public {
        // 1. someone dumps VOL: the pool price collapses
        uint256 priceBefore = pool.priceE18();
        vol.mint(bob, 500e18);
        vm.startPrank(bob);
        vol.approve(address(pool), type(uint256).max);
        pool.swap(true, 500e18, 0, bob);
        vm.stopPrank();
        assertLt(pool.priceE18(), priceBefore / 2);

        // 2. the AI service publishes a high-risk verdict on-chain
        vm.recordLogs();
        vm.prank(ai);
        oracle.publishRisk(92, keccak256("price -55% in 1 swap, volume spike"));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory ev = logs[0];
        assertEq(ev.emitter, address(oracle));

        // 3. Reactive Network delivers that log to the reactive contract
        IReactive.LogRecord memory rec = IReactive.LogRecord({
            chainId: BASE,
            contractAddress: ev.emitter,
            topic0: uint256(ev.topics[0]),
            topic1: uint256(ev.topics[1]),
            topic2: 0,
            topic3: 0,
            data: ev.data,
            blockNumber: block.number,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.prank(SYSTEM_ADDR);
        reactive.react(rec);
        assertEq(sys.callbackCount(), 1);

        // 4. Reactive injects its own address as the first argument and the proxy calls the vault
        (, address recipient,, bytes memory payload) = sys.lastCallback();
        assertEq(recipient, address(vault));
        (address placeholder, uint256 epoch, uint256 score) = this.decodeTail(payload);
        assertEq(placeholder, address(0));
        assertEq(epoch, 1);
        assertEq(score, 92);

        bytes memory injected = abi.encodeWithSelector(
            GuardianVault.deRisk.selector, address(reactive), epoch, score
        );
        vm.prank(PROXY);
        (bool ok,) = address(vault).call(injected);
        assertTrue(ok, "callback must succeed");

        // 5. the vault is now in STABLE and alice can leave with it
        assertTrue(vault.riskOff());
        (uint256 v, uint256 s) = vault.holdings();
        assertEq(v, 0);
        assertGt(s, 0);

        // 6. later, calm verdict (after cooldown) brings the vault back
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(ai);
        oracle.publishRisk(12, keccak256("volatility normalised"));
        _react(2, 12);
        assertEq(sys.callbackCount(), 2);
        _callbackAsProxy(2, false, 12);
        assertFalse(vault.riskOff());
        (v, s) = vault.holdings();
        assertGt(v, 0);
        assertEq(s, 0);
    }

    function test_noAiVerdict_noMovement() public {
        // price crashes but the AI never publishes: nothing downstream moves, users unaffected
        vol.mint(bob, 500e18);
        vm.startPrank(bob);
        vol.approve(address(pool), type(uint256).max);
        pool.swap(true, 500e18, 0, bob);
        vm.stopPrank();

        assertEq(sys.callbackCount(), 0);
        assertFalse(vault.riskOff());
        vm.prank(alice);
        vault.withdraw(100e18);
        assertEq(vol.balanceOf(alice), 100e18);
    }
}
