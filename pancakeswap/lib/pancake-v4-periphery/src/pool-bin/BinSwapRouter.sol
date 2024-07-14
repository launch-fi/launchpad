// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {ILockCallback} from "pancake-v4-core/src/interfaces/ILockCallback.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IBinSwapRouter} from "./interfaces/IBinSwapRouter.sol";
import {BinSwapRouterBase} from "./BinSwapRouterBase.sol";
import {SwapRouterBase} from "../SwapRouterBase.sol";
import {PeripheryImmutableState} from "../base/PeripheryImmutableState.sol";
import {PeripheryPayments} from "../base/PeripheryPayments.sol";
import {PeripheryValidation} from "../base/PeripheryValidation.sol";
import {Multicall} from "../base/Multicall.sol";
import {SelfPermit} from "../base/SelfPermit.sol";

contract BinSwapRouter is
    ILockCallback,
    IBinSwapRouter,
    BinSwapRouterBase,
    PeripheryPayments,
    PeripheryValidation,
    Multicall,
    SelfPermit
{
    using CurrencyLibrary for Currency;

    constructor(IVault _vault, IBinPoolManager _binPoolManager, address _WETH9)
        SwapRouterBase(_vault)
        BinSwapRouterBase(_binPoolManager)
        PeripheryImmutableState(_WETH9)
    {}

    function exactInputSingle(V4BinExactInputSingleParams calldata params, uint256 deadline)
        external
        payable
        override
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        amountOut = abi.decode(
            vault.lock(abi.encode(SwapInfo(SwapType.ExactInputSingle, msg.sender, abi.encode(params)))), (uint256)
        );
    }

    function exactInput(V4BinExactInputParams calldata params, uint256 deadline)
        external
        payable
        override
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        amountOut =
            abi.decode(vault.lock(abi.encode(SwapInfo(SwapType.ExactInput, msg.sender, abi.encode(params)))), (uint256));
    }

    function exactOutputSingle(V4BinExactOutputSingleParams calldata params, uint256 deadline)
        external
        payable
        override
        checkDeadline(deadline)
        returns (uint256 amountIn)
    {
        amountIn = abi.decode(
            vault.lock(abi.encode(SwapInfo(SwapType.ExactOutputSingle, msg.sender, abi.encode(params)))), (uint256)
        );
    }

    function exactOutput(V4BinExactOutputParams calldata params, uint256 deadline)
        external
        payable
        override
        checkDeadline(deadline)
        returns (uint256 amountIn)
    {
        amountIn = abi.decode(
            vault.lock(abi.encode(SwapInfo(SwapType.ExactOutput, msg.sender, abi.encode(params)))), (uint256)
        );
    }

    function lockAcquired(bytes calldata data) external override vaultOnly returns (bytes memory) {
        SwapInfo memory swapInfo = abi.decode(data, (SwapInfo));

        /// @dev By default for SwapRouter, the payer will always be msg.sender and will perform take/settle after the swap.
        V4SettlementParams memory settlementParams =
            V4SettlementParams({payer: swapInfo.msgSender, settle: true, take: true});

        if (swapInfo.swapType == SwapType.ExactInput) {
            return
                abi.encode(_v4BinSwapExactInput(abi.decode(swapInfo.params, (V4BinExactInputParams)), settlementParams));
        } else if (swapInfo.swapType == SwapType.ExactInputSingle) {
            return abi.encode(
                _v4BinSwapExactInputSingle(abi.decode(swapInfo.params, (V4BinExactInputSingleParams)), settlementParams)
            );
        } else if (swapInfo.swapType == SwapType.ExactOutput) {
            return abi.encode(
                _v4BinSwapExactOutput(abi.decode(swapInfo.params, (V4BinExactOutputParams)), settlementParams)
            );
        } else if (swapInfo.swapType == SwapType.ExactOutputSingle) {
            return abi.encode(
                _v4BinSwapExactOutputSingle(
                    abi.decode(swapInfo.params, (V4BinExactOutputSingleParams)), settlementParams
                )
            );
        } else {
            revert InvalidSwapType();
        }
    }

    function _pay(Currency currency, address payer, address recipient, uint256 amount) internal virtual override {
        pay(currency, payer, recipient, amount);
    }
}
