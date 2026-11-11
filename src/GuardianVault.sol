// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

import { MockToken } from "./MockToken.sol";
import { MockPool } from "./MockPool.sol";

/// @title GuardianVault
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
contract GuardianVault is AbstractCallback {
    MockToken public immutable VOL;
    MockToken public immutable STABLE;
    MockPool public immutable POOL;
    address public immutable OWNER;

    uint256 public constant MAX_SLIPPAGE_CAP_BPS = 5_000;
    uint256 public maxSlippageBps = 1_000; // 10% default, generous for a thin demo pool

    bool public riskOff;
    uint256 public lastActedEpoch;

    uint256 public totalShares;
    mapping(address => uint256) public shares;

    event Deposited(address indexed user, uint256 amount, uint256 sharesMinted);
    event Withdrawn(address indexed user, uint256 sharesBurned, uint256 volOut, uint256 stableOut);
    event DeRisked(uint256 indexed epoch, uint256 score, uint256 volSold, uint256 stableReceived);
    event ReRisked(uint256 indexed epoch, uint256 score, uint256 stableSpent, uint256 volReceived);
    /// @dev reason: 1 = stale epoch, 2 = already in requested state
    event CallbackIgnored(uint256 indexed epoch, uint8 reason);
    event MaxSlippageChanged(uint256 bps);

    error NotOwner();
    error ZeroAmount();
    error DepositsPausedWhileRiskOff();
    error InsufficientShares(uint256 have, uint256 want);
    error SlippageTooHigh(uint256 bps);

    constructor(
        IPayable callbackProxy_,
        address reactiveContract_,
        MockToken vol_,
        MockToken stable_,
        MockPool pool_
    ) payable AbstractCallback(callbackProxy_, reactiveContract_) {
        OWNER = msg.sender;
        VOL = vol_;
        STABLE = stable_;
        POOL = pool_;
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

        lastActedEpoch = epoch;
        riskOff = false;

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
