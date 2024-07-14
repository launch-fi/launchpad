// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {IPeripheryPayments} from "../interfaces/IPeripheryPayments.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {PeripheryImmutableState} from "./PeripheryImmutableState.sol";

abstract contract PeripheryPayments is IPeripheryPayments, PeripheryImmutableState {
    using CurrencyLibrary for Currency;
    using SafeTransferLib for ERC20;

    error InsufficientToken();

    // todo: double check
    // in v3, There is a check on "require(msg.sender == WETH9, 'Not WETH9');"
    //  - make sense in v3 as only WETH will send ETH during unwrapETH and there's no native ETH pair in v3
    // in v4, due to native ETH pair, theres a chance ETH is sent from vault or binfungibleposition etc..
    receive() external payable {}

    /// @inheritdoc IPeripheryPayments
    function unwrapWETH9(uint256 amountMinimum, address recipient) public payable override {
        uint256 balanceWETH9 = IWETH9(WETH9).balanceOf(address(this));
        if (balanceWETH9 < amountMinimum) revert InsufficientToken();

        if (balanceWETH9 > 0) {
            IWETH9(WETH9).withdraw(balanceWETH9);
            CurrencyLibrary.NATIVE.transfer(recipient, balanceWETH9);
        }
    }

    /// @inheritdoc IPeripheryPayments
    function refundETH() external payable override {
        if (address(this).balance > 0) CurrencyLibrary.NATIVE.transfer(msg.sender, address(this).balance);
    }

    /// @inheritdoc IPeripheryPayments
    function sweepToken(Currency currency, uint256 amountMinimum, address recipient) public payable override {
        uint256 balanceCurrency = currency.balanceOfSelf();
        if (balanceCurrency < amountMinimum) revert InsufficientToken();

        if (balanceCurrency > 0) {
            currency.transfer(recipient, balanceCurrency);
        }
    }

    /// @dev If currency is native, assumed contract contains the ETH balance
    /// @param currency The currency to pay
    /// @param payer The entity that must pay
    /// @param recipient The entity that will receive payment
    /// @param value The amount to pay
    function pay(Currency currency, address payer, address recipient, uint256 value) internal {
        if (payer == address(this) || currency.isNative()) {
            // currency is native, assume contract owns the ETH currently
            currency.transfer(recipient, value);
        } else {
            // pull payment
            ERC20(Currency.unwrap(currency)).safeTransferFrom(payer, recipient, value);
        }
    }
}
