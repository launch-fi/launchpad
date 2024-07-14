// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {ICLPeripheryImmutableState} from "../interfaces/ICLPeripheryImmutableState.sol";
import {PeripheryImmutableState} from "../../base/PeripheryImmutableState.sol";

/// @title Immutable state
/// @notice Immutable state used by periphery contracts
contract CLPeripheryImmutableState is ICLPeripheryImmutableState, PeripheryImmutableState {
    IVault public immutable vault;

    ICLPoolManager public immutable poolManager;

    constructor(IVault _vault, ICLPoolManager _poolManager, address _WETH9) PeripheryImmutableState(_WETH9) {
        vault = _vault;
        poolManager = _poolManager;
    }
}
