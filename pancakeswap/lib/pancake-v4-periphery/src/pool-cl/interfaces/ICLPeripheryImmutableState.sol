// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IPeripheryImmutableState} from "../../interfaces/IPeripheryImmutableState.sol";

/// @title Immutable state
/// @notice Functions that return immutable state of the router
interface ICLPeripheryImmutableState is IPeripheryImmutableState {
    /// @return Returns the address of the PancakeSwap V4 vault
    function vault() external view returns (IVault);

    /// @return Returns the address of the PancakeSwap V4 pool manager
    function poolManager() external view returns (ICLPoolManager);
}
