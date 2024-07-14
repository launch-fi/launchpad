// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {CLPosition} from "pancake-v4-core/src/pool-cl/libraries/CLPosition.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PeripheryPayments} from "../../base/PeripheryPayments.sol";

import {CLPeripheryImmutableState} from "./CLPeripheryImmutableState.sol";
import {LiquidityAmounts} from "../libraries/LiquidityAmounts.sol";

/// @title Liquidity management functions
/// @notice Internal functions for safely managing liquidity in PancakeSwap V4
abstract contract LiquidityManagement is CLPeripheryImmutableState, PeripheryPayments {
    using PoolIdLibrary for PoolKey;

    error PriceSlippageCheckFailed();

    struct AddLiquidityParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    struct RemoveLiquidityParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        bytes32 salt;
    }

    /// @notice Claim accumulated fees from the position and mint them to the NFP contract
    function mintAccumulatedPositionFee(PoolKey memory poolKey, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
    {
        CLPosition.Info memory poolManagerPositionInfo =
            poolManager.getPosition(poolKey.toId(), address(this), tickLower, tickUpper, salt);

        if (poolManagerPositionInfo.liquidity > 0) {
            (, BalanceDelta feeDelta) = poolManager.modifyLiquidity(
                poolKey, ICLPoolManager.ModifyLiquidityParams(tickLower, tickUpper, 0, salt), ""
            );

            mintFeeDelta(poolKey, feeDelta);
        }
    }

    /// @dev Mint accumulated fee to the contract so user can perform collect() at a later stage
    function mintFeeDelta(PoolKey memory poolKey, BalanceDelta feeDelta) internal {
        if (feeDelta.amount0() > 0) {
            vault.mint(address(this), poolKey.currency0, uint256(int256(feeDelta.amount0())));
        }

        if (feeDelta.amount1() > 0) {
            vault.mint(address(this), poolKey.currency1, uint256(int256(feeDelta.amount1())));
        }
    }

    /// @return liquidity The amount of liquidity added to the position
    /// @return delta The amount of token0 and token1 from liquidity additional. Does not include the fee accumulated in the position.
    function addLiquidity(AddLiquidityParams memory params) internal returns (uint128 liquidity, BalanceDelta delta) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(params.poolKey.toId());
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, params.amount0Desired, params.amount1Desired
        );

        BalanceDelta feeDelta;
        (delta, feeDelta) = poolManager.modifyLiquidity(
            params.poolKey,
            ICLPoolManager.ModifyLiquidityParams(
                params.tickLower, params.tickUpper, int256(uint256(liquidity)), params.salt
            ),
            ""
        );

        /// @dev `delta` return value of modifyLiquidity is inclusive of fee. Mint the `feeDelta` to nfp contract so subtract from `delta`
        delta = delta - feeDelta;
        mintFeeDelta(params.poolKey, feeDelta);

        /// @dev amount0 & amount1 cant be positive here since LPing has been claimed
        if (
            uint256(uint128(-delta.amount0())) < params.amount0Min
                || uint256(uint128(-delta.amount1())) < params.amount1Min
        ) {
            revert PriceSlippageCheckFailed();
        }
    }

    /// @return delta The amount of token0 and token1 from liquidity removal. Does not include the fee accumulated in the position.
    function removeLiquidity(RemoveLiquidityParams memory params) internal returns (BalanceDelta delta) {
        BalanceDelta feeDelta;
        (delta, feeDelta) = poolManager.modifyLiquidity(
            params.poolKey,
            ICLPoolManager.ModifyLiquidityParams(
                params.tickLower, params.tickUpper, -int256(uint256(params.liquidity)), params.salt
            ),
            ""
        );

        /// @dev `delta` return value of modifyLiquidity is inclusive of fee. Mint the `feeDelta` to nfp contract so subtract from `delta`
        delta = delta - feeDelta;
        mintFeeDelta(params.poolKey, feeDelta);

        /// @dev amount0 & amount1 must be positive here since LPing has been claimed
        if (
            uint256(uint128(delta.amount0())) < params.amount0Min
                || uint256(uint128(delta.amount1())) < params.amount1Min
        ) {
            revert PriceSlippageCheckFailed();
        }
    }

    function burnAndTake(Currency currency, address to, uint256 amount) internal {
        vault.burn(address(this), currency, amount);
        vault.take(currency, to, amount);
    }

    function settleDeltas(address sender, PoolKey memory poolKey, BalanceDelta delta) internal {
        if (delta.amount0() > 0) {
            vault.take(poolKey.currency0, sender, uint128(delta.amount0()));
        } else if (delta.amount0() < 0) {
            if (poolKey.currency0.isNative()) {
                vault.settle{value: uint256(int256(-delta.amount0()))}(poolKey.currency0);
            } else {
                vault.sync(poolKey.currency0);
                pay(poolKey.currency0, sender, address(vault), uint256(int256(-delta.amount0())));
                vault.settle(poolKey.currency0);
            }
        }

        if (delta.amount1() > 0) {
            vault.take(poolKey.currency1, sender, uint128(delta.amount1()));
        } else if (delta.amount1() < 0) {
            if (poolKey.currency1.isNative()) {
                vault.settle{value: uint256(int256(-delta.amount1()))}(poolKey.currency1);
            } else {
                vault.sync(poolKey.currency1);
                pay(poolKey.currency1, sender, address(vault), uint256(int256(-delta.amount1())));
                vault.settle(poolKey.currency1);
            }
        }
    }
}
