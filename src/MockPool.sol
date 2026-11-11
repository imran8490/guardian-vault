// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { MockToken } from "./MockToken.sol";

/// @title MockPool
/// @notice Constant-product (x*y=k) VOL/STABLE pool with a 0.3% fee. Exists so the demo can
///         crash the price on purpose with one big swap, which Uniswap on a testnet cannot do
///         on demand. Every swap emits `Swap` with the post-swap spot price: the AI service
///         reads these events to judge risk.
contract MockPool {
    MockToken public immutable VOL;
    MockToken public immutable STABLE;

    uint256 public reserveVol;
    uint256 public reserveStable;

    uint256 private constant FEE_BPS = 30;

    /// @param volToStable true if the caller sold VOL for STABLE.
    /// @param priceE18 STABLE per 1 VOL after the swap, scaled by 1e18.
    event Swap(
        address indexed sender,
        address indexed to,
        bool volToStable,
        uint256 amountIn,
        uint256 amountOut,
        uint256 priceE18
    );
    event LiquidityAdded(address indexed provider, uint256 amountVol, uint256 amountStable);

    error ZeroAmount();
    error InsufficientOutput(uint256 out, uint256 minOut);
    error EmptyPool();

    constructor(MockToken vol_, MockToken stable_) {
        VOL = vol_;
        STABLE = stable_;
    }

    /// @notice Add liquidity. No LP tokens: this is a demo pool, liquidity is not withdrawable.
    function addLiquidity(uint256 amountVol, uint256 amountStable) external {
        if (amountVol == 0 || amountStable == 0) revert ZeroAmount();
        VOL.transferFrom(msg.sender, address(this), amountVol);
        STABLE.transferFrom(msg.sender, address(this), amountStable);
        reserveVol += amountVol;
        reserveStable += amountStable;
        emit LiquidityAdded(msg.sender, amountVol, amountStable);
    }

    /// @notice STABLE per 1 VOL, scaled by 1e18.
    function priceE18() public view returns (uint256) {
        if (reserveVol == 0) revert EmptyPool();
        return (reserveStable * 1e18) / reserveVol;
    }

    /// @notice Output amount for a given input, fee included.
    function getAmountOut(bool volToStable, uint256 amountIn) public view returns (uint256) {
        if (reserveVol == 0 || reserveStable == 0) revert EmptyPool();
        (uint256 rIn, uint256 rOut) =
            volToStable ? (reserveVol, reserveStable) : (reserveStable, reserveVol);
        uint256 inWithFee = amountIn * (10_000 - FEE_BPS);
        return (inWithFee * rOut) / (rIn * 10_000 + inWithFee);
    }

    /// @notice Swap exact input for output sent to `to`. Caller must have approved the input token.
    function swap(bool volToStable, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        amountOut = getAmountOut(volToStable, amountIn);
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        if (volToStable) {
            VOL.transferFrom(msg.sender, address(this), amountIn);
            STABLE.transfer(to, amountOut);
            reserveVol += amountIn;
            reserveStable -= amountOut;
        } else {
            STABLE.transferFrom(msg.sender, address(this), amountIn);
            VOL.transfer(to, amountOut);
            reserveStable += amountIn;
            reserveVol -= amountOut;
        }
        emit Swap(msg.sender, to, volToStable, amountIn, amountOut, priceE18());
    }
}
