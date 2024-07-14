// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";

import {SwapRouterBase} from "../SwapRouterBase.sol";
import {CLSwapRouterBase} from "./CLSwapRouterBase.sol";
import {PeripheryPayments} from "../base/PeripheryPayments.sol";
import {PeripheryValidation} from "../base/PeripheryValidation.sol";
import {PeripheryImmutableState} from "../base/PeripheryImmutableState.sol";
import {Multicall} from "../base/Multicall.sol";
import {SelfPermit} from "../base/SelfPermit.sol";
import {ICLSwapRouter} from "./interfaces/ICLSwapRouter.sol";

contract CLSwapRouter is
    CLSwapRouterBase,
    ICLSwapRouter,
    PeripheryPayments,
    PeripheryValidation,
    Multicall,
    SelfPermit
{
    using CurrencyLibrary for Currency;

    constructor(IVault _vault, ICLPoolManager _clPoolManager, address _WETH9)
        SwapRouterBase(_vault)
        CLSwapRouterBase(_clPoolManager)
        PeripheryImmutableState(_WETH9)
    {}

    function exactInputSingle(V4CLExactInputSingleParams calldata params, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        amountOut = abi.decode(
            vault.lock(abi.encode(SwapInfo(SwapType.ExactInputSingle, msg.sender, abi.encode(params)))), (uint256)
        );
    }

    function exactInput(V4CLExactInputParams calldata params, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        amountOut =
            abi.decode(vault.lock(abi.encode(SwapInfo(SwapType.ExactInput, msg.sender, abi.encode(params)))), (uint256));
    }

    function exactOutputSingle(V4CLExactOutputSingleParams calldata params, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
        returns (uint256 amountIn)
    {
        amountIn = abi.decode(
            vault.lock(abi.encode(SwapInfo(SwapType.ExactOutputSingle, msg.sender, abi.encode(params)))), (uint256)
        );
    }

    function exactOutput(V4CLExactOutputParams calldata params, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
        returns (uint256 amountIn)
    {
        amountIn = abi.decode(
            vault.lock(abi.encode(SwapInfo(SwapType.ExactOutput, msg.sender, abi.encode(params)))), (uint256)
        );
    }

    function lockAcquired(bytes calldata encodedSwapInfo) external vaultOnly returns (bytes memory) {
        SwapInfo memory swapInfo = abi.decode(encodedSwapInfo, (SwapInfo));

        /// @dev By default for SwapRouter, the payer will always be msg.sender and will perform take/settle after the swap.
        V4SettlementParams memory settlementParams =
            V4SettlementParams({payer: swapInfo.msgSender, settle: true, take: true});

        if (swapInfo.swapType == SwapType.ExactInput) {
            return
                abi.encode(_v4CLSwapExactInput(abi.decode(swapInfo.params, (V4CLExactInputParams)), settlementParams));
        } else if (swapInfo.swapType == SwapType.ExactInputSingle) {
            return abi.encode(
                _v4CLSwapExactInputSingle(abi.decode(swapInfo.params, (V4CLExactInputSingleParams)), settlementParams)
            );
        } else if (swapInfo.swapType == SwapType.ExactOutput) {
            return
                abi.encode(_v4CLSwapExactOutput(abi.decode(swapInfo.params, (V4CLExactOutputParams)), settlementParams));
        } else if (swapInfo.swapType == SwapType.ExactOutputSingle) {
            return abi.encode(
                _v4CLSwapExactOutputSingle(abi.decode(swapInfo.params, (V4CLExactOutputSingleParams)), settlementParams)
            );
        } else {
            revert InvalidSwapType();
        }
    }

    function _pay(Currency currency, address payer, address recipient, uint256 amount) internal virtual override {
        pay(currency, payer, recipient, amount);
    }
}
