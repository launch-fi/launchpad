// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {CurrencyLibrary, Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";

import {ISwapRouterBase} from "./interfaces/ISwapRouterBase.sol";

/// @notice General idea of this contract is to provide a base for all swap routers
abstract contract SwapRouterBase is ISwapRouterBase {
    using CurrencyLibrary for Currency;

    error NotVault();

    IVault public immutable vault;

    modifier vaultOnly() {
        if (msg.sender != address(vault)) revert NotVault();
        _;
    }

    constructor(IVault _vault) {
        vault = _vault;
    }

    function _getPoolAndSwapDirection(PathKey memory params, Currency currencyIn)
        internal
        pure
        returns (PoolKey memory poolKey, bool zeroForOne)
    {
        (Currency currency0, Currency currency1) = currencyIn < params.intermediateCurrency
            ? (currencyIn, params.intermediateCurrency)
            : (params.intermediateCurrency, currencyIn);

        zeroForOne = currencyIn == currency0;
        poolKey = PoolKey(currency0, currency1, params.hooks, params.poolManager, params.fee, params.parameters);
    }

    function _payAndSettle(Currency currency, address msgSender, int128 settleAmount) internal virtual {
        if (currency.isNative()) {
            vault.settle{value: uint256(uint128(settleAmount))}(currency);
        } else {
            vault.sync(currency);
            _pay(currency, msgSender, address(vault), uint256(uint128(settleAmount)));
            vault.settle(currency);
        }
    }

    function _pay(Currency currency, address payer, address recipient, uint256 amount) internal virtual;
}
