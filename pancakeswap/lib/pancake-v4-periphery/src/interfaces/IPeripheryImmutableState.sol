// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Immutable state
/// @notice Functions that return immutable state of periphery contract
interface IPeripheryImmutableState {
    /// @return Returns the address of WETH9
    function WETH9() external view returns (address);
}
