// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {ISwapRouterBase} from "../../interfaces/ISwapRouterBase.sol";

interface IBinSwapRouterBase is ISwapRouterBase {
    struct V4BinExactInputSingleParams {
        PoolKey poolKey;
        bool swapForY;
        address recipient;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct V4BinExactInputParams {
        Currency currencyIn;
        PathKey[] path;
        address recipient;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    struct V4BinExactOutputSingleParams {
        PoolKey poolKey;
        bool swapForY;
        address recipient;
        uint128 amountOut;
        uint128 amountInMaximum;
        bytes hookData;
    }

    struct V4BinExactOutputParams {
        Currency currencyOut;
        PathKey[] path;
        address recipient;
        uint128 amountOut;
        uint128 amountInMaximum;
    }
}
