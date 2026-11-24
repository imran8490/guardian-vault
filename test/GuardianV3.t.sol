// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";

import {MockToken} from "../src/MockToken.sol";
import {MockPool} from "../src/MockPool.sol";
import {RiskOracle} from "../src/RiskOracle.sol";
import {GuardianVaultV3} from "../src/GuardianVaultV3.sol";
import {GuardianReactiveV3} from "../src/GuardianReactiveV3.sol";

/// @dev Stand-in for the Reactive system contract: records subscriptions and callback requests.
contract MockSystemV3 {
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

abstract contract V3Base is Test {
    address constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address constant PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    uint256 constant BASE = 84532;
    uint256 constant T0 = 1_000_000;

    uint8 constant HIGH = 70;
    uint8 constant LOW = 30;
    uint256 constant COOLDOWN = 60;
    uint256 constant MAX_AGE = 600;
    uint256 constant BREAKER_BPS = 4_000; // stop level 40% below entry
    uint256 constant GRACE = 30;
    uint256 constant CRON = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    MockSystemV3 sys;
    MockToken vol;
    MockToken stable;
    MockPool pool;
    RiskOracle oracle;
    GuardianReactiveV3 reactive;
    GuardianVaultV3 vault;

    address ai = makeAddr("ai");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public virtual {
        vm.warp(T0);
        vm.etch(SYSTEM_ADDR, address(new MockSystemV3()).code);
        sys = MockSystemV3(SYSTEM_ADDR);

        vol = new MockToken("Volatile", "VOL");
        stable = new MockToken("Stable", "STBL");
        pool = new MockPool(vol, stable);

        vol.mint(address(this), 1_000e18);
        stable.mint(address(this), 1_000e18);
        vol.approve(address(pool), type(uint256).max);
        stable.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1_000e18, 1_000e18);

        oracle = new RiskOracle(ai);
        reactive = new GuardianReactiveV3(
            BASE,
            address(oracle),
            address(pool),
            BASE,
            HIGH,
            LOW,
            COOLDOWN,
            MAX_AGE,
            1e18,
            BREAKER_BPS,
            GRACE,
            CRON
        );
        vault = new GuardianVaultV3(
            IPayable(payable(PROXY)),
            address(reactive),
            vol,
            stable,
            pool,
            oracle,
            HIGH,
            LOW,
            MAX_AGE,
            BREAKER_BPS
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

    // ---- log builders

    function _verdictLog(uint256 epoch, uint8 score, uint256 publishedAt)
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

    function _swapLog(uint256 priceE18) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: BASE,
            contractAddress: address(pool),
            topic0: reactive.SWAP_TOPIC_0(),
            topic1: uint256(uint160(bob)),
            topic2: uint256(uint160(bob)),
            topic3: 0,
            data: abi.encode(true, uint256(1e18), uint256(1e18), priceE18),
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _cronLog() internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: 5318007,
            contractAddress: reactive.CRON_SOURCE(),
            topic0: CRON,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(block.number),
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    // ---- reactions

    function _react(IReactive.LogRecord memory l) internal {
        vm.prank(SYSTEM_ADDR);
        reactive.react(l);
    }

    function _reactVerdict(uint256 epoch, uint8 score) internal {
        _react(_verdictLog(epoch, score, block.timestamp));
    }

    function _reactSwap(uint256 priceE18) internal {
        _react(_swapLog(priceE18));
    }

    /// @dev The AI signer publishes a verdict on the oracle; returns its epoch.
    function _verdict(uint8 score) internal returns (uint256 epoch) {
        vm.prank(ai);
        epoch = oracle.publishRisk(score, keccak256(abi.encode("test verdict", score)));
    }

    /// @dev A real, big sell on the pool: price falls below 0.5.
    function _crash() internal {
        vol.mint(bob, 500e18);
        vm.startPrank(bob);
        vol.approve(address(pool), type(uint256).max);
        pool.swap(true, 500e18, 0, bob);
        vm.stopPrank();
    }

    /// @dev Delivers the callback that Reactive just requested, the way the real network does: the
    ///      payload's first argument (a placeholder) is overwritten with the reactive contract's address.
    function _deliverLastCallback() internal returns (bool ok) {
        (, address recipient,, bytes memory payload) = sys.lastCallback();
        assertEq(recipient, address(vault), "callback targets the vault");
        bytes memory patched = payload;
        bytes memory addrWord = abi.encode(address(reactive));
        for (uint256 i = 0; i < 32; i++) {
            patched[4 + i] = addrWord[i];
        }
        vm.prank(PROXY);
        (ok,) = recipient.call(patched);
    }

    function _lastCallbackSelector() internal view returns (bytes4 sel) {
        (,,, bytes memory payload) = sys.lastCallback();
        assembly {
            sel := mload(add(payload, 32))
        }
    }
}

// =============================================================================== reactive: subscriptions + config

contract ReactiveV3ConfigTest is V3Base {
    function test_subscribesToOraclePoolAndCron() public view {
        assertEq(sys.subsLength(), 3);
        (uint256 c0, address a0, uint256 t0) = sys.subs(0);
        assertEq(c0, BASE);
        assertEq(a0, address(oracle));
        assertEq(t0, reactive.RISK_TOPIC_0());
        (uint256 c1, address a1, uint256 t1) = sys.subs(1);
        assertEq(c1, BASE);
        assertEq(a1, address(pool));
        assertEq(t1, reactive.SWAP_TOPIC_0());
        (, address a2, uint256 t2) = sys.subs(2);
        assertEq(a2, reactive.CRON_SOURCE());
        assertEq(t2, CRON);
    }

    function test_watchdogOff_subscribesToOracleOnly() public {
        sys = MockSystemV3(SYSTEM_ADDR);
        uint256 before_ = sys.subsLength();
        new GuardianReactiveV3(
            BASE, address(oracle), address(pool), BASE, HIGH, LOW, COOLDOWN, MAX_AGE, 0, 0, 0, 0
        );
        assertEq(sys.subsLength(), before_ + 1);
    }

    function test_cronOptional_noCronSubscriptionWhenZero() public {
        uint256 before_ = sys.subsLength();
        new GuardianReactiveV3(
            BASE,
            address(oracle),
            address(pool),
            BASE,
            HIGH,
            LOW,
            COOLDOWN,
            MAX_AGE,
            1e18,
            BREAKER_BPS,
            GRACE,
            0
        );
        assertEq(sys.subsLength(), before_ + 2); // oracle + pool, no cron
    }

    function test_swapTopicMatchesRealPoolEvent() public {
        vm.recordLogs();
        _crash();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory sw = logs[logs.length - 1];
        assertEq(sw.emitter, address(pool));
        assertEq(uint256(sw.topics[0]), reactive.SWAP_TOPIC_0());
        (,,, uint256 price) = abi.decode(sw.data, (bool, uint256, uint256, uint256));
        assertEq(price, pool.priceE18());
    }

    function test_badConfigReverts() public {
        vm.expectRevert(GuardianReactiveV3.BadConfig.selector);
        new GuardianReactiveV3(
            BASE,
            address(oracle),
            address(pool),
            BASE,
            HIGH,
            LOW,
            COOLDOWN,
            MAX_AGE,
            1e18,
            9_001,
            GRACE,
            0
        );
        vm.expectRevert(GuardianReactiveV3.BadConfig.selector);
        new GuardianReactiveV3(
            BASE,
            address(oracle),
            address(pool),
            BASE,
            HIGH,
            LOW,
            COOLDOWN,
            MAX_AGE,
            0,
            4_000,
            GRACE,
            0
        );
        vm.expectRevert(GuardianReactiveV3.BadConfig.selector);
        new GuardianReactiveV3(
            BASE,
            address(oracle),
            address(0),
            BASE,
            HIGH,
            LOW,
            COOLDOWN,
            MAX_AGE,
            1e18,
            4_000,
            GRACE,
            0
        );
        vm.expectRevert(GuardianReactiveV3.BadConfig.selector);
        new GuardianReactiveV3(
            BASE,
            address(oracle),
            address(pool),
            BASE,
            30,
            30,
            COOLDOWN,
            MAX_AGE,
            1e18,
            4_000,
            GRACE,
            0
        );
    }

    function test_vaultBadConfigReverts() public {
        vm.expectRevert(GuardianVaultV3.BadConfig.selector);
        new GuardianVaultV3(
            IPayable(payable(PROXY)),
            address(reactive),
            vol,
            stable,
            pool,
            oracle,
            HIGH,
            LOW,
            MAX_AGE,
            9_001
        );
    }

    function test_stopPrice() public view {
        assertEq(reactive.stopPriceE18(), 0.6e18);
        assertEq(reactive.entryPriceE18(), 1e18);
    }

    function test_reactOnlyBySystem() public {
        IReactive.LogRecord memory l = _swapLog(0.5e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, alice, SYSTEM_ADDR)
        );
        reactive.react(l);
    }

    function test_setVaultOnce_andOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(GuardianReactiveV3.NotOwner.selector);
        reactive.setVault(alice);
        vm.expectRevert(GuardianReactiveV3.VaultAlreadySet.selector);
        reactive.setVault(alice);
    }
}

// =============================================================================== reactive: AI path (regression of v2 behaviour)

contract ReactiveV3AiPathTest is V3Base {
    function test_highVerdict_requestsDeRisk() public {
        _reactVerdict(1, 85);
        assertTrue(reactive.riskOff());
        assertEq(sys.callbackCount(), 1);
        assertEq(_lastCallbackSelector(), bytes4(keccak256("deRisk(address,uint256,uint256)")));
    }

    function test_hysteresis_middleBandDoesNothing() public {
        _reactVerdict(1, 50);
        assertFalse(reactive.riskOff());
        assertEq(sys.callbackCount(), 0);
        _reactVerdict(2, 69);
        assertEq(sys.callbackCount(), 0);
        _reactVerdict(3, 70);
        assertEq(sys.callbackCount(), 1);
    }

    function test_reRiskOnlyAtLowThreshold() public {
        _reactVerdict(1, 90);
        vm.warp(block.timestamp + COOLDOWN);
        _reactVerdict(2, 31);
        assertEq(sys.callbackCount(), 1);
        _reactVerdict(3, 30);
        assertEq(sys.callbackCount(), 2);
        assertFalse(reactive.riskOff());
        assertEq(_lastCallbackSelector(), bytes4(keccak256("reRisk(address,uint256,uint256)")));
    }

    function test_cooldownBlocksFastFlip() public {
        _reactVerdict(1, 90);
        _reactVerdict(2, 5);
        assertEq(sys.callbackCount(), 1);
        assertTrue(reactive.riskOff());
    }

    function test_replayedAndStaleEpochsIgnored() public {
        _reactVerdict(5, 90);
        vm.warp(block.timestamp + COOLDOWN);
        _reactVerdict(5, 5);
        _reactVerdict(4, 5);
        assertEq(sys.callbackCount(), 1);
        assertEq(reactive.lastEpoch(), 5);
    }

    function test_tooOldVerdictIgnored() public {
        _react(_verdictLog(1, 95, block.timestamp - MAX_AGE - 1));
        assertEq(sys.callbackCount(), 0);
        assertFalse(reactive.riskOff());
    }

    function test_foreignLogsIgnored() public {
        IReactive.LogRecord memory l = _verdictLog(1, 95, block.timestamp);
        l.contractAddress = address(0xdead);
        _react(l);
        l = _verdictLog(1, 95, block.timestamp);
        l.chainId = 1;
        _react(l);
        l = _swapLog(0.1e18);
        l.contractAddress = address(0xdead);
        _react(l);
        assertEq(sys.callbackCount(), 0);
        assertEq(reactive.swapCount(), 0);
    }

    function test_verdictCounters() public {
        _reactVerdict(1, 90);
        assertEq(reactive.reactCount(), 1);
        assertEq(reactive.actionCount(), 1);
    }
}

// =============================================================================== reactive: watchdog

contract ReactiveV3WatchdogTest is V3Base {
    function test_swapAboveStop_nothingHappens() public {
        _reactSwap(0.7e18);
        assertEq(reactive.breachSince(), 0);
        assertEq(sys.callbackCount(), 0);
        assertEq(reactive.lastPriceE18(), 0.7e18);
        assertEq(reactive.swapCount(), 1);
    }

    function test_breachStartsGraceTimer_noCallbackYet() public {
        vm.expectEmit(false, false, false, true);
        emit GuardianReactiveV3.BreachSeen(0.5e18, 0.6e18);
        _reactSwap(0.5e18);
        assertEq(reactive.breachSince(), block.timestamp);
        assertEq(sys.callbackCount(), 0);
        assertFalse(reactive.riskOff());
    }

    function test_stopLevelIsInclusive() public {
        _reactSwap(0.6e18);
        assertEq(reactive.breachSince(), block.timestamp);
    }

    function test_tripsAfterGrace_onNextSwap() public {
        _reactSwap(0.5e18);
        vm.warp(block.timestamp + GRACE);
        vm.expectEmit(true, false, false, true);
        emit GuardianReactiveV3.BreakerTripped(1, 1e18, 0.45e18, GRACE);
        _reactSwap(0.45e18);
        assertTrue(reactive.riskOff());
        assertEq(sys.callbackCount(), 1);
        assertEq(_lastCallbackSelector(), bytes4(keccak256("breakerDeRisk(address,uint256)")));
        assertEq(reactive.breakerCount(), 1);
        assertEq(reactive.breachSince(), 0);
    }

    function test_doesNotTripBeforeGrace() public {
        _reactSwap(0.5e18);
        vm.warp(block.timestamp + GRACE - 1);
        _reactSwap(0.45e18);
        assertEq(sys.callbackCount(), 0);
        assertFalse(reactive.riskOff());
    }

    function test_recoveryClearsBreach() public {
        _reactSwap(0.5e18);
        vm.expectEmit(false, false, false, true);
        emit GuardianReactiveV3.BreachCleared(0.9e18);
        _reactSwap(0.9e18);
        assertEq(reactive.breachSince(), 0);
        vm.warp(block.timestamp + GRACE * 4);
        _reactSwap(0.95e18);
        assertEq(sys.callbackCount(), 0);
    }

    function test_cronTickWakesTheWatchdog_withNoFurtherSwaps() public {
        _reactSwap(0.5e18);
        vm.warp(block.timestamp + GRACE + 1);
        _react(_cronLog());
        assertEq(reactive.tickCount(), 1);
        assertTrue(reactive.riskOff());
        assertEq(sys.callbackCount(), 1);
    }

    function test_cronTickBeforeGrace_doesNothing() public {
        _reactSwap(0.5e18);
        vm.warp(block.timestamp + GRACE - 1);
        _react(_cronLog());
        assertEq(sys.callbackCount(), 0);
    }

    function test_aiVerdictAlsoWakesTheWatchdog() public {
        _reactSwap(0.5e18);
        vm.warp(block.timestamp + GRACE + 1);
        // a mid-band verdict: the AI path does nothing, but the event wakes the watchdog
        _reactVerdict(1, 50);
        assertTrue(reactive.riskOff());
        assertEq(sys.callbackCount(), 1);
        assertEq(_lastCallbackSelector(), bytes4(keccak256("breakerDeRisk(address,uint256)")));
    }

    function test_aiGetsTheFirstChance_watchdogStaysQuiet() public {
        _reactSwap(0.5e18);
        _reactVerdict(1, 90); // AI path de-risks within the grace period
        assertEq(sys.callbackCount(), 1);
        assertEq(_lastCallbackSelector(), bytes4(keccak256("deRisk(address,uint256,uint256)")));
        vm.warp(block.timestamp + GRACE * 5);
        _reactSwap(0.4e18);
        _react(_cronLog());
        assertEq(sys.callbackCount(), 1, "no second de-risk");
        assertEq(reactive.breakerCount(), 0);
    }

    function test_verdictAndBreachInSameMoment_aiWins() public {
        _reactSwap(0.5e18);
        vm.warp(block.timestamp + GRACE + 1);
        // grace has expired, but the AI verdict arrives first in the same react call
        _reactVerdict(1, 95);
        assertEq(sys.callbackCount(), 1);
        assertEq(_lastCallbackSelector(), bytes4(keccak256("deRisk(address,uint256,uint256)")));
        assertEq(reactive.breakerCount(), 0);
    }

    function test_noRetripWhileRiskOff() public {
        _reactSwap(0.5e18);
        vm.warp(block.timestamp + GRACE);
        _reactSwap(0.45e18);
        assertEq(sys.callbackCount(), 1);
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + GRACE);
            _reactSwap(0.3e18);
            _react(_cronLog());
        }
        assertEq(sys.callbackCount(), 1);
        assertEq(reactive.breakerCount(), 1);
    }

    function test_reRiskAfterBreaker_isAiDriven_andResetsEntry() public {
        _reactSwap(0.5e18);
        vm.warp(block.timestamp + GRACE);
        _reactSwap(0.45e18);
        // price recovers to 0.8; AI says calm; cooldown has passed
        vm.warp(block.timestamp + COOLDOWN);
        _reactSwap(0.8e18);
        assertEq(sys.callbackCount(), 1, "price alone never re-risks");
        _reactVerdict(1, 10);
        assertEq(sys.callbackCount(), 2);
        assertEq(_lastCallbackSelector(), bytes4(keccak256("reRisk(address,uint256,uint256)")));
        assertFalse(reactive.riskOff());
        assertEq(reactive.entryPriceE18(), 0.8e18, "stop level re-based on the re-entry price");
        assertEq(reactive.stopPriceE18(), 0.48e18);
    }

    function test_graceZero_tripsOnFirstBreach() public {
        reactive = new GuardianReactiveV3(
            BASE,
            address(oracle),
            address(pool),
            BASE,
            HIGH,
            LOW,
            COOLDOWN,
            MAX_AGE,
            1e18,
            BREAKER_BPS,
            0,
            0
        );
        reactive.setVault(address(vault));
        _reactSwap(0.5e18);
        assertTrue(reactive.riskOff());
        assertEq(sys.callbackCount(), 1);
    }

    function test_watchdogDisabled_ignoresSwaps() public {
        reactive = new GuardianReactiveV3(
            BASE, address(oracle), address(pool), BASE, HIGH, LOW, COOLDOWN, MAX_AGE, 0, 0, 0, 0
        );
        reactive.setVault(address(vault));
        _reactSwap(0.1e18);
        vm.warp(block.timestamp + 1 days);
        _reactSwap(0.05e18);
        assertEq(sys.callbackCount(), 0);
        assertEq(reactive.swapCount(), 0);
    }

    function test_overrideClearsBreach() public {
        _reactSwap(0.5e18);
        assertGt(reactive.breachSince(), 0);
        reactive.overrideRiskState(false);
        assertEq(reactive.breachSince(), 0);
    }

    function test_cronLogFromWrongSourceIgnored() public {
        _reactSwap(0.5e18);
        vm.warp(block.timestamp + GRACE + 1);
        IReactive.LogRecord memory l = _cronLog();
        l.contractAddress = address(0xbeef);
        _react(l);
        assertEq(reactive.tickCount(), 0);
        assertEq(sys.callbackCount(), 0);
    }
}

// =============================================================================== vault: watchdog path

contract VaultV3BreakerTest is V3Base {
    function _breaker(uint256 seq) internal {
        vm.prank(PROXY);
        vault.breakerDeRisk(address(reactive), seq);
    }

    function test_entryPriceRecordedAtDeploy() public view {
        assertEq(vault.entryPriceE18(), 1e18);
        assertEq(vault.BREAKER_BPS(), BREAKER_BPS);
    }

    function test_breakerSellsAllWhenPoolPriceIsBelowStop() public {
        _crash();
        assertLt(pool.priceE18(), 0.6e18);
        (uint256 volBefore,) = vault.holdings();

        vm.expectEmit(true, false, false, false);
        emit GuardianVaultV3.BreakerDeRisked(1, 0, 0, 0, 0);
        _breaker(1);

        assertTrue(vault.riskOff());
        (uint256 v, uint256 s) = vault.holdings();
        assertEq(v, 0);
        assertGt(s, 0);
        assertEq(volBefore, 100e18);
        assertEq(vault.lastBreakerSeq(), 1);
    }

    function test_breakerRefusedWhenPriceIsNotDown() public {
        // Reactive's claim is irrelevant: the pool price is still 1.0
        vm.expectEmit(true, false, false, true);
        emit GuardianVaultV3.BreakerRejected(1, 3, 1e18);
        _breaker(1);
        assertFalse(vault.riskOff());
        (uint256 v,) = vault.holdings();
        assertEq(v, 100e18, "no trade");
        assertEq(vault.lastBreakerSeq(), 0);
    }

    function test_breakerRefusedWhenAlreadyRiskOff() public {
        _crash();
        _breaker(1);
        vm.expectEmit(true, false, false, false);
        emit GuardianVaultV3.BreakerRejected(2, 2, 0);
        _breaker(2);
    }

    function test_breakerReplayRefused() public {
        _crash();
        _breaker(1);
        vm.expectEmit(true, false, false, false);
        emit GuardianVaultV3.BreakerRejected(1, 4, 0);
        _breaker(1);
        vm.expectEmit(true, false, false, false);
        emit GuardianVaultV3.BreakerRejected(0, 4, 0);
        _breaker(0);
    }

    function test_breakerDisabledVault_refuses() public {
        GuardianVaultV3 v2 = new GuardianVaultV3(
            IPayable(payable(PROXY)),
            address(reactive),
            vol,
            stable,
            pool,
            oracle,
            HIGH,
            LOW,
            MAX_AGE,
            0
        );
        _crash();
        vm.expectEmit(true, false, false, false);
        emit GuardianVaultV3.BreakerRejected(1, 1, 0);
        vm.prank(PROXY);
        v2.breakerDeRisk(address(reactive), 1);
        assertFalse(v2.riskOff());
    }

    function test_onlyProxyAndOnlyOurReactive() public {
        _crash();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, alice, PROXY));
        vault.breakerDeRisk(address(reactive), 1);

        vm.prank(PROXY);
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractCallback.CallbackNotAuthorized.selector, alice, address(reactive)
            )
        );
        vault.breakerDeRisk(alice, 1);
    }

    function test_userCanWithdrawAfterBreaker_andDepositsPaused() public {
        _crash();
        _breaker(1);
        vol.mint(bob, 1e18);
        vm.startPrank(bob);
        vol.approve(address(vault), type(uint256).max);
        vm.expectRevert(GuardianVaultV3.DepositsPausedWhileRiskOff.selector);
        vault.deposit(1e18);
        vm.stopPrank();
        vm.prank(alice);
        (uint256 vOut, uint256 sOut) = vault.withdraw(100e18);
        assertEq(vOut, 0);
        assertGt(sOut, 0);
    }

    function test_reRiskIsStillOracleChecked_andRebasesEntry() public {
        _crash();
        _breaker(1);
        uint256 e = _verdict(90); // oracle says danger: the vault must refuse to re-enter
        vm.prank(PROXY);
        vault.reRisk(address(reactive), e, 10);
        assertTrue(vault.riskOff(), "still risk-off: oracle does not justify re-risk");

        vm.warp(block.timestamp + 1);
        uint256 e2 = _verdict(10);
        uint256 priceBefore = pool.priceE18();
        vm.prank(PROXY);
        vault.reRisk(address(reactive), e2, 10);
        assertFalse(vault.riskOff());
        assertEq(vault.entryPriceE18(), priceBefore, "stop level re-based on the re-entry price");
    }

    function test_breakerDoesNotTouchAiEpochCounter() public {
        _crash();
        _breaker(1);
        assertEq(vault.lastActedEpoch(), 0);
    }

    function test_aiPathStillWorksOnV3Vault() public {
        uint256 e = _verdict(90);
        vm.prank(PROXY);
        vault.deRisk(address(reactive), e, 90);
        assertTrue(vault.riskOff());
    }

    function test_aiPathStillRejectsCalmOracle() public {
        uint256 e = _verdict(10);
        vm.expectEmit(true, false, false, true);
        emit GuardianVaultV3.CallbackRejected(e, 1, 10);
        vm.prank(PROXY);
        vault.deRisk(address(reactive), e, 90);
        assertFalse(vault.riskOff());
    }

    /// Property: whatever the crash size, whatever the stop level, the vault only ever sells through
    /// the watchdog when the pool price is really at or below its own stop level.
    function testFuzz_breakerNeverSellsAbovePrice(uint256 dump, uint256 bps) public {
        dump = bound(dump, 1e18, 900e18);
        bps = bound(bps, 1, 9_000);
        GuardianVaultV3 v = new GuardianVaultV3(
            IPayable(payable(PROXY)),
            address(reactive),
            vol,
            stable,
            pool,
            oracle,
            HIGH,
            LOW,
            MAX_AGE,
            bps
        );
        vol.mint(address(v), 0); // empty vault; the property is about the decision, not the trade
        vol.mint(bob, dump);
        vm.startPrank(bob);
        vol.approve(address(pool), type(uint256).max);
        pool.swap(true, dump, 0, bob);
        vm.stopPrank();

        uint256 stop = (v.entryPriceE18() * (10_000 - bps)) / 10_000;
        vm.prank(PROXY);
        v.breakerDeRisk(address(reactive), 1);
        assertEq(v.riskOff(), pool.priceE18() <= stop);
    }
}

// =============================================================================== end to end wiring

contract V3WiringTest is V3Base {
    /// @dev Turns the pool's real Swap log (as recorded by Foundry) into the LogRecord Reactive would pass.
    function _toRecord(Vm.Log memory l) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: BASE,
            contractAddress: l.emitter,
            topic0: uint256(l.topics[0]),
            topic1: l.topics.length > 1 ? uint256(l.topics[1]) : 0,
            topic2: l.topics.length > 2 ? uint256(l.topics[2]) : 0,
            topic3: l.topics.length > 3 ? uint256(l.topics[3]) : 0,
            data: l.data,
            blockNumber: 1,
            opCode: 0,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _feedPoolSwaps(Vm.Log[] memory logs) internal {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(pool)
                    && uint256(logs[i].topics[0]) == reactive.SWAP_TOPIC_0()
            ) {
                _react(_toRecord(logs[i]));
            }
        }
    }

    function test_realCrash_aiSilent_watchdogProtectsTheVault() public {
        vm.recordLogs();
        _crash(); // real pool swap
        _feedPoolSwaps(vm.getRecordedLogs()); // Reactive sees the real Swap event
        assertEq(sys.callbackCount(), 0, "grace period running, no callback yet");

        vm.warp(block.timestamp + GRACE + 1); // the AI service never speaks
        _react(_cronLog());

        assertEq(sys.callbackCount(), 1);
        assertTrue(_deliverLastCallback(), "payload decodes into breakerDeRisk on the real vault");
        assertTrue(vault.riskOff());
        (uint256 v, uint256 s) = vault.holdings();
        assertEq(v, 0);
        assertGt(s, 40e18);
    }

    function test_realCrash_aiActsFirst_watchdogNeverFires() public {
        vm.recordLogs();
        _crash();
        _feedPoolSwaps(vm.getRecordedLogs());

        uint256 e = _verdict(100);
        _react(_verdictLog(e, 100, block.timestamp));
        assertEq(_lastCallbackSelector(), bytes4(keccak256("deRisk(address,uint256,uint256)")));
        assertTrue(_deliverLastCallback());
        assertTrue(vault.riskOff());

        vm.warp(block.timestamp + GRACE * 4);
        _react(_cronLog());
        assertEq(sys.callbackCount(), 1);
        assertEq(reactive.breakerCount(), 0);
    }

    function test_realCrash_vaultVetoesWhenReactiveIsWrong() public {
        // A buggy or hostile reactive layer asks for a breaker de-risk while the pool is healthy.
        vm.prank(PROXY);
        vault.breakerDeRisk(address(reactive), 1);
        assertFalse(vault.riskOff());
        (uint256 v,) = vault.holdings();
        assertEq(v, 100e18);
    }

    function test_fullCycle_breaker_then_aiReRisk() public {
        vm.recordLogs();
        _crash();
        _feedPoolSwaps(vm.getRecordedLogs());
        vm.warp(block.timestamp + GRACE);
        _react(_cronLog());
        assertTrue(_deliverLastCallback());
        assertTrue(vault.riskOff());

        // recovery: price comes back, AI calls it calm, Reactive asks for a re-risk, vault re-checks the oracle
        vm.warp(block.timestamp + COOLDOWN);
        stable.mint(bob, 800e18);
        vm.startPrank(bob);
        stable.approve(address(pool), type(uint256).max);
        vm.recordLogs();
        pool.swap(false, 800e18, 0, bob);
        vm.stopPrank();
        _feedPoolSwaps(vm.getRecordedLogs());

        vm.warp(block.timestamp + 1);
        uint256 e = _verdict(10);
        _react(_verdictLog(e, 10, block.timestamp));
        assertEq(_lastCallbackSelector(), bytes4(keccak256("reRisk(address,uint256,uint256)")));
        assertTrue(_deliverLastCallback());
        assertFalse(vault.riskOff());
        assertEq(
            vault.entryPriceE18(),
            reactive.entryPriceE18(),
            "vault and reactive agree on the re-entry price"
        );
        (uint256 v,) = vault.holdings();
        assertGt(v, 0);
    }
}
