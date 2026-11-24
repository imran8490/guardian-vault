// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @title GuardianReactiveV3
/// @notice GuardianReactive plus a watchdog. Same AI path as v2 (hysteresis, cooldown, staleness,
///         replay protection), and in addition it watches the pool itself.
///
/// Why a watchdog: in v2 everything starts from an AI verdict. If the AI service is down, late, or
/// confidently wrong, a crash is not answered. v3 adds a second, deliberately dumb path that does
/// not need the AI:
///   - it subscribes to the pool's `Swap` events and keeps the last price it saw;
///   - the stop level is BREAKER_BPS below the "entry price" (the price at which the vault last went
///     risk-on; the first value is passed in at deploy);
///   - when the price is at or below the stop level it starts a grace timer. If the AI path has not
///     moved the vault by the time the timer runs out, it trips and asks the vault to de-risk.
/// The AI therefore always gets the first chance (it normally acts within seconds, long before the
/// grace period ends); the watchdog only acts when the AI did not.
///
/// The watchdog needs something to wake it after the grace period: any later Swap or oracle event
/// does, and so does the optional Reactive Cron subscription (CRON_TOPIC_0, 0 = off).
/// The vault does not trust this contract's price either: `breakerDeRisk` re-reads the pool and
/// refuses unless the price really is below the vault's own stop level.
contract GuardianReactiveV3 is AbstractReactive {
    // keccak256("RiskUpdated(uint256,uint8,uint256,bytes32)")
    uint256 public constant RISK_TOPIC_0 =
        uint256(keccak256("RiskUpdated(uint256,uint8,uint256,bytes32)"));
    // keccak256("Swap(address,address,bool,uint256,uint256,uint256)")
    uint256 public constant SWAP_TOPIC_0 =
        uint256(keccak256("Swap(address,address,bool,uint256,uint256,uint256)"));
    /// @dev Cron events are emitted by the Reactive protocol itself from this address.
    address public constant CRON_SOURCE = 0x0000000000000000000000000000000000fffFfF;
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    uint256 public immutable ORACLE_CHAIN_ID;
    address public immutable ORACLE;
    address public immutable POOL;
    uint256 public immutable DESTINATION_CHAIN_ID;
    address public immutable OWNER;

    uint8 public immutable HIGH_THRESHOLD;
    uint8 public immutable LOW_THRESHOLD;
    uint256 public immutable COOLDOWN;
    uint256 public immutable MAX_AGE;

    /// @dev Stop level in basis points below the entry price. 0 disables the watchdog.
    uint256 public immutable BREAKER_BPS;
    /// @dev Seconds the price must stay at or below the stop level, with the AI path not having
    ///      moved the vault, before the watchdog trips.
    uint256 public immutable GRACE;
    /// @dev Cron topic0 to subscribe to for wake-ups, or 0 for none.
    uint256 public immutable CRON_TOPIC_0;

    address public vault;
    bool public riskOff;
    uint256 public lastEpoch;
    uint256 public lastActionAt;

    uint256 public entryPriceE18;
    uint256 public lastPriceE18;
    /// @dev Timestamp at which the price was first seen at or below the stop level (0 = not below).
    uint256 public breachSince;

    uint256 public reactCount;
    uint256 public actionCount;
    uint256 public swapCount;
    uint256 public tickCount;
    uint256 public breakerCount;

    event ActionRequested(uint256 indexed epoch, uint8 score, bool deRisk);
    /// @dev reason: 1 stale epoch, 2 verdict too old, 3 cooldown, 4 no action needed
    event Skipped(uint256 indexed epoch, uint8 score, uint8 reason);
    event RiskStateOverridden(bool riskOff);
    event BreachSeen(uint256 priceE18, uint256 stopPriceE18);
    event BreachCleared(uint256 priceE18);
    event BreakerTripped(
        uint256 indexed seq, uint256 entryPriceE18, uint256 priceE18, uint256 breachedForSeconds
    );

    error NotOwner();
    error VaultAlreadySet();
    error VaultNotSet();
    error BadConfig();

    constructor(
        uint256 oracleChainId_,
        address oracle_,
        address pool_,
        uint256 destinationChainId_,
        uint8 high_,
        uint8 low_,
        uint256 cooldown_,
        uint256 maxAge_,
        uint256 entryPriceE18_,
        uint256 breakerBps_,
        uint256 grace_,
        uint256 cronTopic0_
    ) payable {
        if (
            low_ >= high_ || high_ > 100 || maxAge_ == 0 || pool_ == address(0)
                || breakerBps_ > 9_000 || (breakerBps_ != 0 && entryPriceE18_ == 0)
        ) revert BadConfig();
        OWNER = msg.sender;
        ORACLE_CHAIN_ID = oracleChainId_;
        ORACLE = oracle_;
        POOL = pool_;
        DESTINATION_CHAIN_ID = destinationChainId_;
        HIGH_THRESHOLD = high_;
        LOW_THRESHOLD = low_;
        COOLDOWN = cooldown_;
        MAX_AGE = maxAge_;
        BREAKER_BPS = breakerBps_;
        GRACE = grace_;
        CRON_TOPIC_0 = cronTopic0_;
        entryPriceE18 = entryPriceE18_;
        lastPriceE18 = entryPriceE18_;

        SYSTEM.subscribe(
            oracleChainId_, oracle_, RISK_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        if (breakerBps_ != 0) {
            SYSTEM.subscribe(
                oracleChainId_,
                pool_,
                SWAP_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
            if (cronTopic0_ != 0) {
                SYSTEM.subscribe(
                    block.chainid,
                    CRON_SOURCE,
                    cronTopic0_,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
            }
        }
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
        breachSince = 0;
        emit RiskStateOverridden(riskOff_);
    }

    /// @notice The price at or below which the watchdog starts its grace timer.
    function stopPriceE18() public view returns (uint256) {
        return (entryPriceE18 * (10_000 - BREAKER_BPS)) / 10_000;
    }

    function react(LogRecord calldata log_) external override onlySystem {
        address vault_ = vault;
        if (vault_ == address(0)) revert VaultNotSet();

        if (
            log_.topic0 == RISK_TOPIC_0 && log_.chainId == ORACLE_CHAIN_ID
                && log_.contractAddress == ORACLE
        ) {
            _onVerdict(vault_, log_);
        } else if (
            BREAKER_BPS != 0 && log_.topic0 == SWAP_TOPIC_0 && log_.chainId == ORACLE_CHAIN_ID
                && log_.contractAddress == POOL
        ) {
            unchecked {
                ++swapCount;
            }
            (,,, uint256 price) = abi.decode(log_.data, (bool, uint256, uint256, uint256));
            lastPriceE18 = price;
        } else if (
            BREAKER_BPS != 0 && CRON_TOPIC_0 != 0 && log_.topic0 == CRON_TOPIC_0
                && log_.contractAddress == CRON_SOURCE
        ) {
            unchecked {
                ++tickCount;
            }
        } else {
            return;
        }

        _checkBreaker(vault_);
    }

    // ------------------------------------------------------------------ AI path (unchanged from v2)

    function _onVerdict(address vault_, LogRecord calldata log_) internal {
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
        if (wantDeRisk) {
            // The AI path moved the vault; nothing left for the watchdog to do for this crash.
            breachSince = 0;
        } else {
            // Re-entering: the stop level is measured from the price we are re-entering at.
            if (lastPriceE18 != 0) entryPriceE18 = lastPriceE18;
            breachSince = 0;
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

    // ------------------------------------------------------------------ watchdog

    /// @dev Runs after every handled event (verdict, swap, cron tick), so the AI path has always had
    ///      its chance first when both react to the same moment.
    function _checkBreaker(address vault_) internal {
        if (BREAKER_BPS == 0 || riskOff) return;

        uint256 stop = stopPriceE18();
        if (lastPriceE18 > stop) {
            if (breachSince != 0) {
                breachSince = 0;
                emit BreachCleared(lastPriceE18);
            }
            return;
        }

        if (breachSince == 0) {
            breachSince = block.timestamp;
            emit BreachSeen(lastPriceE18, stop);
            if (GRACE != 0) return;
        }
        if (block.timestamp < breachSince + GRACE) return;

        riskOff = true;
        lastActionAt = block.timestamp;
        uint256 seq;
        unchecked {
            seq = ++breakerCount;
            ++actionCount;
        }
        emit BreakerTripped(seq, entryPriceE18, lastPriceE18, block.timestamp - breachSince);
        breachSince = 0;

        bytes memory payload =
            abi.encodeWithSignature("breakerDeRisk(address,uint256)", address(0), seq);
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
