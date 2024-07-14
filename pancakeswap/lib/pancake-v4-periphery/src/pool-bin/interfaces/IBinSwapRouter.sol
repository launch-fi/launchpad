// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {IBinSwapRouterBase} from "./IBinSwapRouterBase.sol";

interface IBinSwapRouter is IBinSwapRouterBase {
    enum SwapType {
        ExactInput,
        ExactInputSingle,
        ExactOutput,
        ExactOutputSingle
    }

    struct SwapInfo {
        SwapType swapType;
        address msgSender;
        bytes params;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @param params The parameters necessary for the swap, encoded as `V4BinExactInputSingleParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInputSingle(V4BinExactInputSingleParams calldata params, uint256 deadline)
        external
        payable
        returns (uint256 amountOut);

    // / @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    // / @param params The parameters necessary for the multi-hop swap, encoded as `V4BinExactInputParams` in calldata
    // / @return amountOut The amount of the received token
    function exactInput(V4BinExactInputParams calldata params, uint256 deadline)
        external
        payable
        returns (uint256 amountOut);

    /// @notice Swaps as little as possible of one token for `amountOut` of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactOutputSingleParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutputSingle(V4BinExactOutputSingleParams calldata params, uint256 deadline)
        external
        payable
        returns (uint256 amountIn);

    /// @notice Swaps as little as possible of one token for `amountOut` of another along the specified path (reversed)
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactOutputParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutput(V4BinExactOutputParams calldata params, uint256 deadline)
        external
        payable
        returns (uint256 amountIn);
}
