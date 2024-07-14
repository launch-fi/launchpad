// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId} from "pancake-v4-core/src/types/PoolId.sol";
import {IBinFungibleToken} from "./IBinFungibleToken.sol";

interface IBinFungiblePositionManager is IBinFungibleToken {
    error OnlyVaultCaller();
    error IdOverflows(int256);
    error IdDesiredOverflows(uint24);
    error DeadlineExceeded(uint256, uint256);
    error InputLengthMismatch();
    error AddLiquidityInputActiveIdMismath();
    error OutputAmountSlippage();
    error IncorrectOutputAmount();
    error InvalidTokenID();

    /// @notice AddLiquidityParams
    /// - amount0: Amount to send for token0
    /// - amount1: Amount to send for token1
    /// - amount0Min: Min amount to send for token0
    /// - amount1Min: Min amount to send for token1
    /// - activeIdDesired: Active id that user wants to add liquidity from
    /// - idSlippage: Number of id that are allowed to slip
    /// - deltaIds: List of delta ids to add liquidity (`deltaId = activeId - desiredId`)
    /// - distributionX: Distribution of tokenX with sum(distributionX) = 100e18 (100%) or 0 (0%)
    /// - distributionY: Distribution of tokenY with sum(distributionY) = 100e18 (100%) or 0 (0%)
    /// - to: Address of recipient
    /// - deadline: Deadline of transaction
    struct AddLiquidityParams {
        PoolKey poolKey;
        uint128 amount0;
        uint128 amount1;
        uint128 amount0Min;
        uint128 amount1Min;
        uint256 activeIdDesired;
        uint256 idSlippage;
        int256[] deltaIds;
        uint256[] distributionX;
        uint256[] distributionY;
        address to;
        uint256 deadline;
    }

    /// @notice RemoveLiquidityParams
    /// - amount0Min: Min amount to recieve for token0
    /// - amount1Min: Min amount to recieve for token1
    /// - ids: List of bin ids to remove liquidity
    /// - amounts: List of share amount to remove for each bin
    /// - from: Address of NFT holder to burn the NFT
    /// - to: Address of recipient for amount0 and amount1 recieved
    /// - deadline: Deadline of transaction
    struct RemoveLiquidityParams {
        PoolKey poolKey;
        uint128 amount0Min;
        uint128 amount1Min;
        uint256[] ids;
        uint256[] amounts;
        address from;
        address to;
        uint256 deadline;
    }

    enum CallbackDataType {
        AddLiquidity,
        RemoveLiquidity
    }

    struct CallbackData {
        address sender;
        CallbackDataType callbackDataType;
        bytes params;
    }

    /// @return the address of bin pool manager
    function poolManager() external view returns (IBinPoolManager);

    /// @return the address of vault
    function vault() external view returns (IVault);

    /// @notice Return the position information associated with a given tokenId
    /// @dev Revert if non-existent tokenId
    /// @param tokenId Id of the token that represent position
    function positions(uint256 tokenId)
        external
        view
        returns (Currency currency0, Currency currency1, uint24 fee, uint24 binId);

    /// @notice Initialize a new pool
    /// @dev Call this when the pool does not exist and is not initialized
    /// @param poolKey The pool key
    /// @param activeId The active id of the pool
    /// @param hookData Hook data for the pool
    function initialize(PoolKey memory poolKey, uint24 activeId, bytes calldata hookData) external;

    /// @notice Add liquidity, user will receive ERC1155 tokens as receipt of bin share ownership.
    /// @dev The ID of the ERC11155 token is keccak256(abi.encode(poolkey.toId, binId))
    /// @return amount0 Amount of token0 added
    /// @return amount1 Amount of token1 added
    /// @return tokenIds Ids of token minted
    /// @return liquidityMinted Amount of liquidity added
    function addLiquidity(AddLiquidityParams calldata)
        external
        payable
        returns (uint128 amount0, uint128 amount1, uint256[] memory tokenIds, uint256[] memory liquidityMinted);

    /// @notice Remove liquidity, burn NFT and retrieve back the ERC20 tokens for the liquidity
    /// @return amount0 Amount of token0 removed
    /// @return amount1 Amount of token1 removed
    /// @return tokenIds Ids of token burnt
    function removeLiquidity(RemoveLiquidityParams calldata)
        external
        payable
        returns (uint128 amount0, uint128 amount1, uint256[] memory tokenIds);
}
