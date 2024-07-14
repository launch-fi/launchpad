// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {SwapRouterBase} from "../SwapRouterBase.sol";
import {IBinSwapRouterBase} from "./interfaces/IBinSwapRouterBase.sol";

abstract contract BinSwapRouterBase is SwapRouterBase, IBinSwapRouterBase {
    using CurrencyLibrary for Currency;
    using SafeCast for uint128;

    IBinPoolManager public immutable binPoolManager;

    constructor(IBinPoolManager _binPoolManager) {
        binPoolManager = _binPoolManager;
    }

    /// @notice Perform a swap with `amountIn` in and ensure at least `amountOutMinimum` out
    function _v4BinSwapExactInputSingle(
        V4BinExactInputSingleParams memory params,
        V4SettlementParams memory settlementParams
    ) internal returns (uint256 amountOut) {
        amountOut = uint256(
            _swapExactPrivate(
                params.poolKey,
                params.swapForY,
                settlementParams.payer,
                params.recipient,
                -(params.amountIn.safeInt128()),
                settlementParams.settle,
                settlementParams.take,
                params.hookData
            )
        );

        if (amountOut < params.amountOutMinimum) revert TooLittleReceived();
    }

    struct V4BinExactInputState {
        uint256 pathLength;
        PoolKey poolKey;
        bool swapForY;
        uint128 amountOut;
    }

    /// @notice Perform a swap with `amountIn` in and ensure at least `amountOutMinimum` out
    function _v4BinSwapExactInput(V4BinExactInputParams memory params, V4SettlementParams memory settlementParams)
        internal
        returns (uint256 amountOut)
    {
        V4BinExactInputState memory state;
        state.pathLength = params.path.length;

        for (uint256 i = 0; i < state.pathLength; i++) {
            (state.poolKey, state.swapForY) = _getPoolAndSwapDirection(params.path[i], params.currencyIn);

            state.amountOut = _swapExactPrivate(
                state.poolKey,
                state.swapForY,
                settlementParams.payer,
                params.recipient,
                -(params.amountIn.safeInt128()),
                i == 0 && settlementParams.settle, // only settle at first iteration AND settle = true
                i == state.pathLength - 1 && settlementParams.take, // only take at last iteration AND take = true
                params.path[i].hookData
            );

            params.amountIn = state.amountOut;
            params.currencyIn = params.path[i].intermediateCurrency;
        }

        if (state.amountOut < params.amountOutMinimum) revert TooLittleReceived();
        return uint256(state.amountOut);
    }

    /// @notice Perform a swap that ensure at least `amountOut` tokens with `amountInMaximum` tokens
    function _v4BinSwapExactOutputSingle(
        V4BinExactOutputSingleParams memory params,
        V4SettlementParams memory settlementParams
    ) internal returns (uint256 amountIn) {
        amountIn = uint256(
            _swapExactPrivate(
                params.poolKey,
                params.swapForY,
                settlementParams.payer,
                params.recipient,
                params.amountOut.safeInt128(),
                settlementParams.settle,
                settlementParams.take,
                params.hookData
            )
        );

        if (amountIn > params.amountInMaximum) revert TooMuchRequested();
    }

    struct V4BinExactOutputState {
        uint256 pathLength;
        PoolKey poolKey;
        bool swapForY;
        uint128 amountIn;
    }

    /// @notice Perform a swap that ensure at least `amountOut` tokens with `amountInMaximum` tokens
    function _v4BinSwapExactOutput(V4BinExactOutputParams memory params, V4SettlementParams memory settlementParams)
        internal
        returns (uint256 amountIn)
    {
        V4BinExactOutputState memory state;
        state.pathLength = params.path.length;

        /// @dev Iterate backward from last path to first path
        for (uint256 i = state.pathLength; i > 0;) {
            // Step 1: Find out poolKey and how much amountIn required to get amountOut
            (state.poolKey, state.swapForY) = _getPoolAndSwapDirection(params.path[i - 1], params.currencyOut);

            state.amountIn = _swapExactPrivate(
                state.poolKey,
                !state.swapForY,
                settlementParams.payer,
                params.recipient,
                params.amountOut.safeInt128(),
                i == 1 && settlementParams.settle, // only settle at first swap AND settle = true
                i == state.pathLength && settlementParams.take, // only take at last iteration AND take = true
                params.path[i - 1].hookData
            );

            params.amountOut = state.amountIn;
            params.currencyOut = params.path[i - 1].intermediateCurrency;

            unchecked {
                --i;
            }
        }

        if (state.amountIn > params.amountInMaximum) revert TooMuchRequested();
        amountIn = uint256(state.amountIn);
    }

    function _swapExactPrivate(
        PoolKey memory poolKey,
        bool swapForY,
        address payer,
        address recipient,
        int128 amountSpecified,
        bool settle,
        bool take,
        bytes memory hookData
    ) private returns (uint128 reciprocalAmount) {
        BalanceDelta delta = binPoolManager.swap(poolKey, swapForY, amountSpecified, hookData);

        if (swapForY) {
            /// @dev amountSpecified < 0 indicate exactInput, so reciprocal token is token1 and positive
            ///      amountSpecified > 0 indicate exactOutput, so reciprocal token is token0 but is negative
            unchecked {
                /// unchecked as we are sure that the amount is within uint128
                reciprocalAmount = amountSpecified < 0 ? uint128(delta.amount1()) : uint128(-delta.amount0());
            }

            if (settle) _payAndSettle(poolKey.currency0, payer, -delta.amount0());
            if (take) vault.take(poolKey.currency1, recipient, uint128(delta.amount1()));
        } else {
            unchecked {
                reciprocalAmount = amountSpecified < 0 ? uint128(delta.amount0()) : uint128(-delta.amount1());
            }

            if (settle) _payAndSettle(poolKey.currency1, payer, -delta.amount1());
            if (take) vault.take(poolKey.currency0, recipient, uint128(delta.amount0()));
        }
    }
}
