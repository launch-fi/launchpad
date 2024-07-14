// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {IPeripheryImmutableState} from "../interfaces/IPeripheryImmutableState.sol";

abstract contract PeripheryImmutableState is IPeripheryImmutableState {
    address public immutable WETH9;

    constructor(address _WETH9) {
        WETH9 = _WETH9;
    }
}
