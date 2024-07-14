// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {ICLSwapRouterBase} from "./ICLSwapRouterBase.sol";

interface ICLSwapRouter is ICLSwapRouterBase {
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
    /// @param params The parameters necessary for the swap, encoded as `V4CLExactInputSingleParams` in calldata
    /// @param deadline A timestamp, the current blocktime must be less than or equal to this timestamp
    /// @return amountOut The amount of the received token
    function exactInputSingle(V4CLExactInputSingleParams calldata params, uint256 deadline)
        external
        payable
        returns (uint256 amountOut);

    /// @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    /// @param params The parameters necessary for the multi-hop swap, encoded as `V4CLExactInputParams` in calldata
    /// @param deadline A timestamp, the current blocktime must be less than or equal to this timestamp
    /// @return amountOut The amount of the received token
    function exactInput(V4CLExactInputParams calldata params, uint256 deadline)
        external
        payable
        returns (uint256 amountOut);

    /// @notice Swaps as little as possible of one token for `amountOut` of another token
    /// @param params The parameters necessary for the swap, encoded as `V4CLExactOutputSingleParams` in calldata
    /// @param deadline A timestamp, the current blocktime must be less than or equal to this timestamp
    /// @return amountIn The amount of the input token
    function exactOutputSingle(V4CLExactOutputSingleParams calldata params, uint256 deadline)
        external
        payable
        returns (uint256 amountIn);

    /// @notice Swaps as little as possible of one token for `amountOut` of another along the specified path (reversed)
    /// @param params The parameters necessary for the multi-hop swap, encoded as `V4CLExactOutputParams` in calldata
    /// @param deadline A timestamp, the current blocktime must be less than or equal to this timestamp
    /// @return amountIn The amount of the input token
    function exactOutput(V4CLExactOutputParams calldata params, uint256 deadline)
        external
        payable
        returns (uint256 amountIn);
}
