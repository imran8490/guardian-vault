// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";

import {MockToken} from "./MockToken.sol";
import {MockPool} from "./MockPool.sol";
import {RiskOracle} from "./RiskOracle.sol";

/// @title GuardianVaultV3
/// @notice Holds a volatile asset (VOL) for depositors. When the AI-driven reactive contract
///         signals danger, the vault sells VOL into STABLE; when the danger passes it buys back.
///
/// Security model (read this before the code):
///  1. Users can ALWAYS withdraw. Nothing here can lock funds; if the AI, the oracle or Reactive
///     Network all go down, the vault simply stays in whatever state it is in and withdraw() works.
///  2. `deRisk` / `reRisk` are callable ONLY by the callback proxy (onlyServiceProvider) AND only
///     when the proxy-injected sender equals our reactive contract (onlyCallbackSender). Anyone
///     else reverts, so nobody can force the vault to trade.
///  3. Every trade has a slippage guard against the pool's spot price, and a replayed or stale
///     callback (epoch not newer than the last one acted on) is ignored.
///  4. Deposits are paused while risk-off, so nobody enters at a stale valuation.
///  5. Independent verdict check: the vault does not take the Reactive contract's word for it. Before
///     it trades it reads the RiskOracle ITSELF and refuses (CallbackRejected, no trade) unless the
///     oracle's latest verdict is fresh and really justifies the move (score >= HIGH to de-risk,
///     <= LOW to re-risk). A buggy or compromised reactive layer cannot move funds on its own, and a
///     verdict that has since been superseded by a calmer one cannot sell the vault.
///  6. (v3) Watchdog path: `breakerDeRisk` lets the Reactive contract de-risk WITHOUT an AI verdict, but
///     only when the vault's own reading of the pool shows the price at or below the vault's own stop
///     level (BREAKER_BPS below the entry price the vault recorded when it last went risk-on). The
///     vault never uses a price or a threshold supplied by the callback, so a wrong or compromised
///     reactive layer still cannot sell the vault at a price that is not actually down. Going back to
///     risk-on is always AI-driven and oracle-checked (`reRisk`), never automatic.
contract GuardianVaultV3 is AbstractCallback {
    MockToken public immutable VOL;
    MockToken public immutable STABLE;
    MockPool public immutable POOL;
    RiskOracle public immutable ORACLE;
    address public immutable OWNER;

    /// @dev Mirror GuardianReactive's thresholds; the vault re-checks them against the oracle.
    uint8 public immutable HIGH_THRESHOLD;
    uint8 public immutable LOW_THRESHOLD;
    uint256 public immutable MAX_VERDICT_AGE;
    /// @dev Stop level in basis points below the entry price. 0 disables the watchdog path.
    uint256 public immutable BREAKER_BPS;

    uint256 public constant MAX_SLIPPAGE_CAP_BPS = 5_000;
    uint256 public maxSlippageBps = 1_000; // 10% default, generous for a thin demo pool

    bool public riskOff;
    uint256 public lastActedEpoch;
    /// @dev Pool price (STABLE per VOL, 1e18) when the vault last went risk-on; the stop level is measured from it.
    uint256 public entryPriceE18;
    uint256 public lastBreakerSeq;

    uint256 public totalShares;
    mapping(address => uint256) public shares;

    event Deposited(address indexed user, uint256 amount, uint256 sharesMinted);
    event Withdrawn(address indexed user, uint256 sharesBurned, uint256 volOut, uint256 stableOut);
    event DeRisked(uint256 indexed epoch, uint256 score, uint256 volSold, uint256 stableReceived);
    event ReRisked(uint256 indexed epoch, uint256 score, uint256 stableSpent, uint256 volReceived);
    /// @dev reason: 1 = stale epoch, 2 = already in requested state
    event CallbackIgnored(uint256 indexed epoch, uint8 reason);
    /// @dev reason: 1 = oracle's latest score does not justify this action, 2 = oracle's latest
    ///      verdict is older than MAX_VERDICT_AGE, 3 = callback epoch is ahead of the oracle's epoch
    event CallbackRejected(uint256 indexed epoch, uint8 reason, uint8 oracleScore);
    event MaxSlippageChanged(uint256 bps);
    event BreakerDeRisked(
        uint256 indexed seq,
        uint256 entryPriceE18,
        uint256 poolPriceE18,
        uint256 volSold,
        uint256 stableReceived
    );
    /// @dev reason: 1 watchdog disabled, 2 already risk-off, 3 pool price is not at or below the stop level,
    ///      4 replayed or old sequence number
    event BreakerRejected(uint256 indexed seq, uint8 reason, uint256 poolPriceE18);

    error NotOwner();
    error ZeroAmount();
    error DepositsPausedWhileRiskOff();
    error InsufficientShares(uint256 have, uint256 want);
    error SlippageTooHigh(uint256 bps);
    error BadConfig();

    constructor(
        IPayable callbackProxy_,
        address reactiveContract_,
        MockToken vol_,
        MockToken stable_,
        MockPool pool_,
        RiskOracle oracle_,
        uint8 high_,
        uint8 low_,
        uint256 maxVerdictAge_,
        uint256 breakerBps_
    ) payable AbstractCallback(callbackProxy_, reactiveContract_) {
        if (
            low_ >= high_ || high_ > 100 || maxVerdictAge_ == 0 || address(oracle_) == address(0)
                || breakerBps_ > 9_000
        ) {
            revert BadConfig();
        }
        OWNER = msg.sender;
        VOL = vol_;
        STABLE = stable_;
        POOL = pool_;
        ORACLE = oracle_;
        HIGH_THRESHOLD = high_;
        LOW_THRESHOLD = low_;
        MAX_VERDICT_AGE = maxVerdictAge_;
        BREAKER_BPS = breakerBps_;
        entryPriceE18 = pool_.priceE18();
    }

    // ------------------------------------------------------------------ users

    function deposit(uint256 amount) external returns (uint256 minted) {
        if (amount == 0) revert ZeroAmount();
        if (riskOff) revert DepositsPausedWhileRiskOff();

        uint256 volBefore = VOL.balanceOf(address(this));
        minted = (totalShares == 0 || volBefore == 0) ? amount : (amount * totalShares) / volBefore;

        shares[msg.sender] += minted;
        totalShares += minted;
        VOL.transferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount, minted);
    }

    /// @notice Burn shares for a pro-rata slice of whatever the vault holds (VOL, STABLE, or both).
    function withdraw(uint256 shareAmount) external returns (uint256 volOut, uint256 stableOut) {
        if (shareAmount == 0) revert ZeroAmount();
        uint256 have = shares[msg.sender];
        if (shareAmount > have) revert InsufficientShares(have, shareAmount);

        volOut = (VOL.balanceOf(address(this)) * shareAmount) / totalShares;
        stableOut = (STABLE.balanceOf(address(this)) * shareAmount) / totalShares;

        // effects before interactions
        shares[msg.sender] = have - shareAmount;
        totalShares -= shareAmount;

        if (volOut > 0) VOL.transfer(msg.sender, volOut);
        if (stableOut > 0) STABLE.transfer(msg.sender, stableOut);
        emit Withdrawn(msg.sender, shareAmount, volOut, stableOut);
    }

    function holdings() external view returns (uint256 vol, uint256 stable) {
        return (VOL.balanceOf(address(this)), STABLE.balanceOf(address(this)));
    }

    // ------------------------------------------------- callbacks (Reactive only)

    /// @param reactive_ Overwritten by Reactive Network with the requesting reactive contract's address.
    function deRisk(address reactive_, uint256 epoch, uint256 score)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        if (epoch <= lastActedEpoch) {
            emit CallbackIgnored(epoch, 1);
            return;
        }
        if (riskOff) {
            emit CallbackIgnored(epoch, 2);
            return;
        }
        if (!_verdictJustifies(epoch, true)) return;

        lastActedEpoch = epoch;
        riskOff = true;

        uint256 amount = VOL.balanceOf(address(this));
        uint256 received;
        if (amount > 0) {
            uint256 quote = (amount * POOL.priceE18()) / 1e18;
            uint256 minOut = (quote * (10_000 - maxSlippageBps)) / 10_000;
            VOL.approve(address(POOL), amount);
            received = POOL.swap(true, amount, minOut, address(this));
        }
        emit DeRisked(epoch, score, amount, received);
    }

    function reRisk(address reactive_, uint256 epoch, uint256 score)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        if (epoch <= lastActedEpoch) {
            emit CallbackIgnored(epoch, 1);
            return;
        }
        if (!riskOff) {
            emit CallbackIgnored(epoch, 2);
            return;
        }
        if (!_verdictJustifies(epoch, false)) return;

        lastActedEpoch = epoch;
        riskOff = false;
        entryPriceE18 = POOL.priceE18();

        uint256 amount = STABLE.balanceOf(address(this));
        uint256 received;
        if (amount > 0) {
            uint256 quote = (amount * 1e18) / POOL.priceE18();
            uint256 minOut = (quote * (10_000 - maxSlippageBps)) / 10_000;
            STABLE.approve(address(POOL), amount);
            received = POOL.swap(false, amount, minOut, address(this));
        }
        emit ReRisked(epoch, score, amount, received);
    }

    /// @notice Watchdog de-risk. Needs no AI verdict, but trades only if the vault's own reading of the
    ///         pool says the price is at or below the stop level. Refusals are successful transactions
    ///         that emit BreakerRejected, like CallbackRejected on the AI path.
    /// @param reactive_ Overwritten by Reactive Network with the requesting reactive contract's address.
    /// @param seq Reactive's watchdog trip counter; older or repeated values are refused.
    function breakerDeRisk(address reactive_, uint256 seq)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        uint256 price = POOL.priceE18();
        uint8 reason;
        if (seq <= lastBreakerSeq) {
            reason = 4;
        } else if (BREAKER_BPS == 0) {
            reason = 1;
        } else if (riskOff) {
            reason = 2;
        } else if (price > (entryPriceE18 * (10_000 - BREAKER_BPS)) / 10_000) {
            reason = 3;
        }
        if (reason != 0) {
            emit BreakerRejected(seq, reason, price);
            return;
        }

        lastBreakerSeq = seq;
        riskOff = true;

        uint256 amount = VOL.balanceOf(address(this));
        uint256 received;
        if (amount > 0) {
            uint256 quote = (amount * price) / 1e18;
            uint256 minOut = (quote * (10_000 - maxSlippageBps)) / 10_000;
            VOL.approve(address(POOL), amount);
            received = POOL.swap(true, amount, minOut, address(this));
        }
        emit BreakerDeRisked(seq, entryPriceE18, price, amount, received);
    }

    /// @dev Reads the oracle directly (not the callback's arguments) and emits CallbackRejected
    ///      instead of reverting, so the refusal is a visible, successful transaction on-chain.
    function _verdictJustifies(uint256 epoch, bool toRiskOff) internal returns (bool) {
        uint8 score = ORACLE.latestScore();
        uint8 reason;
        if (epoch > ORACLE.epoch()) {
            reason = 3;
        } else if (block.timestamp > ORACLE.latestTimestamp() + MAX_VERDICT_AGE) {
            reason = 2;
        } else if (toRiskOff ? score < HIGH_THRESHOLD : score > LOW_THRESHOLD) {
            reason = 1;
        }
        if (reason != 0) {
            emit CallbackRejected(epoch, reason, score);
            return false;
        }
        return true;
    }

    // ------------------------------------------------------------------ admin

    function setMaxSlippageBps(uint256 bps) external {
        if (msg.sender != OWNER) revert NotOwner();
        if (bps > MAX_SLIPPAGE_CAP_BPS) revert SlippageTooHigh(bps);
        maxSlippageBps = bps;
        emit MaxSlippageChanged(bps);
    }

    /// @notice Anyone may settle outstanding callback fees from this contract's ETH balance.
    function coverDebt() external {
        _coverDebt();
    }
}
