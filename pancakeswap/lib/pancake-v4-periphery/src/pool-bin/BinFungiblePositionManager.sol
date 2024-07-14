// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ILockCallback} from "pancake-v4-core/src/interfaces/ILockCallback.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPool} from "pancake-v4-core/src/pool-bin/libraries/BinPool.sol";
import {LiquidityConfigurations} from "pancake-v4-core/src/pool-bin/libraries/math/LiquidityConfigurations.sol";
import {PackedUint128Math} from "pancake-v4-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {BinFungibleToken} from "./BinFungibleToken.sol";
import {IBinFungiblePositionManager} from "./interfaces/IBinFungiblePositionManager.sol";
import {PeripheryPayments} from "../base/PeripheryPayments.sol";
import {PeripheryValidation} from "../base/PeripheryValidation.sol";
import {Multicall} from "../base/Multicall.sol";
import {PeripheryImmutableState} from "../base/PeripheryImmutableState.sol";
import {BinTokenLibrary} from "./libraries/BinTokenLibrary.sol";

contract BinFungiblePositionManager is
    ILockCallback,
    IBinFungiblePositionManager,
    BinFungibleToken,
    PeripheryPayments,
    PeripheryValidation,
    Multicall
{
    using CurrencyLibrary for Currency;
    using PackedUint128Math for bytes32;
    using PackedUint128Math for uint128;
    using PoolIdLibrary for PoolKey;
    using BinTokenLibrary for PoolId;
    using BinPoolParametersHelper for bytes32;

    bytes constant ZERO_BYTES = new bytes(0);

    IVault public immutable override vault;
    IBinPoolManager public immutable override poolManager;

    struct TokenPosition {
        PoolId poolId;
        uint24 binId;
    }

    /// @dev tokenId => TokenPosition
    mapping(uint256 => TokenPosition) private _positions;

    /// @dev poolId => poolKey
    mapping(bytes32 => PoolKey) private _poolIdToPoolKey;

    constructor(IVault _vault, IBinPoolManager _poolManager, address _WETH9) PeripheryImmutableState(_WETH9) {
        vault = _vault;
        poolManager = _poolManager;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (Currency currency0, Currency currency1, uint24 fee, uint24 binId)
    {
        TokenPosition memory position = _positions[tokenId];

        if (PoolId.unwrap(position.poolId) == 0) revert InvalidTokenID();
        PoolKey memory poolKey = _poolIdToPoolKey[PoolId.unwrap(position.poolId)];

        // todo: sync with CL if we want to return other poolkey val eg. hooks / poolManager or parameters
        return (poolKey.currency0, poolKey.currency1, poolKey.fee, position.binId);
    }

    /// @dev Store poolKey in mapping for lookup
    function cachePoolKey(PoolKey memory poolKey) private returns (PoolId poolId) {
        poolId = poolKey.toId();

        if (_poolIdToPoolKey[PoolId.unwrap(poolId)].parameters.getBinStep() == 0) {
            _poolIdToPoolKey[PoolId.unwrap(poolId)] = poolKey;
        }
    }

    /// @inheritdoc IBinFungiblePositionManager
    function initialize(PoolKey memory poolKey, uint24 activeId, bytes calldata hookData) external override {
        poolManager.initialize(poolKey, activeId, hookData);
    }

    /// @inheritdoc IBinFungiblePositionManager
    function addLiquidity(AddLiquidityParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint128 amount0, uint128 amount1, uint256[] memory tokenIds, uint256[] memory liquidityMinted)
    {
        if (
            params.deltaIds.length != params.distributionX.length
                || params.deltaIds.length != params.distributionY.length
        ) {
            revert InputLengthMismatch();
        }

        if (params.activeIdDesired > type(uint24).max || params.idSlippage > type(uint24).max) {
            revert AddLiquidityInputActiveIdMismath();
        }

        (amount0, amount1, tokenIds, liquidityMinted) = abi.decode(
            vault.lock(abi.encode(CallbackData(msg.sender, CallbackDataType.AddLiquidity, abi.encode(params)))),
            (uint128, uint128, uint256[], uint256[])
        );

        emit TransferBatch(msg.sender, address(0), params.to, tokenIds, liquidityMinted);
    }

    /// @inheritdoc IBinFungiblePositionManager
    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        checkApproval(params.from, msg.sender)
        returns (uint128 amount0, uint128 amount1, uint256[] memory tokenIds)
    {
        if (params.ids.length != params.amounts.length) revert InputLengthMismatch();

        (amount0, amount1, tokenIds) = abi.decode(
            vault.lock(abi.encode(CallbackData(msg.sender, CallbackDataType.RemoveLiquidity, abi.encode(params)))),
            (uint128, uint128, uint256[])
        );

        emit TransferBatch(msg.sender, params.from, address(0), tokenIds, params.amounts);
    }

    function lockAcquired(bytes calldata rawData) external override returns (bytes memory returnData) {
        if (msg.sender != address(vault)) revert OnlyVaultCaller();

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        if (data.callbackDataType == CallbackDataType.AddLiquidity) {
            AddLiquidityParams memory params = abi.decode(data.params, (AddLiquidityParams));

            /// @dev Checks if the activeId is within slippage before calling mint. If user mint to activeId and there
            //       was a swap in hook.beforeMint() which changes the activeId, user txn will fail
            (uint24 activeId,,) = poolManager.getSlot0(params.poolKey.toId());
            if (
                params.activeIdDesired + params.idSlippage < activeId
                    || params.activeIdDesired - params.idSlippage > activeId
            ) {
                revert IdDesiredOverflows(activeId);
            }

            bytes32[] memory liquidityConfigs = new bytes32[](params.deltaIds.length);
            for (uint256 i; i < liquidityConfigs.length;) {
                int256 _id = int256(uint256(activeId)) + params.deltaIds[i];
                if (_id < 0 || uint256(_id) > type(uint24).max) revert IdOverflows(_id);

                liquidityConfigs[i] = LiquidityConfigurations.encodeParams(
                    uint64(params.distributionX[i]), uint64(params.distributionY[i]), uint24(uint256(_id))
                );

                unchecked {
                    ++i;
                }
            }

            bytes32 amountIn = params.amount0.encode(params.amount1);
            (BalanceDelta delta, BinPool.MintArrays memory mintArray) = poolManager.mint(
                params.poolKey,
                IBinPoolManager.MintParams({liquidityConfigs: liquidityConfigs, amountIn: amountIn, salt: bytes32(0)}),
                ZERO_BYTES
            );

            // delta amt0/amt1 will always be negative in mint case
            if (delta.amount0() > 0 || delta.amount1() > 0) revert IncorrectOutputAmount();
            if (uint128(-delta.amount0()) < params.amount0Min || uint128(-delta.amount1()) < params.amount1Min) {
                revert OutputAmountSlippage();
            }

            _settleDeltas(data.sender, params.poolKey, delta);

            // mint
            PoolId poolId = cachePoolKey(params.poolKey);
            uint256[] memory tokenIds = new uint256[](mintArray.ids.length);
            for (uint256 i; i < mintArray.ids.length;) {
                uint256 tokenId = poolId.toTokenId(mintArray.ids[i]);
                _mint(params.to, tokenId, mintArray.liquidityMinted[i]);

                if (_positions[tokenId].binId == 0) {
                    _positions[tokenId] = TokenPosition({poolId: poolId, binId: uint24(mintArray.ids[i])});
                }

                tokenIds[i] = tokenId;
                unchecked {
                    ++i;
                }
            }

            return abi.encode(uint128(-delta.amount0()), uint128(-delta.amount1()), tokenIds, mintArray.liquidityMinted);
        } else if (data.callbackDataType == CallbackDataType.RemoveLiquidity) {
            RemoveLiquidityParams memory params = abi.decode(data.params, (RemoveLiquidityParams));

            BalanceDelta delta = poolManager.burn(
                params.poolKey,
                IBinPoolManager.BurnParams({ids: params.ids, amountsToBurn: params.amounts, salt: bytes32(0)}),
                ZERO_BYTES
            );

            // delta amt0/amt1 will either be 0 or positive in removing liquidity
            if (delta.amount0() < 0 || delta.amount1() < 0) revert IncorrectOutputAmount();
            if (uint128(delta.amount0()) < params.amount0Min || uint128(delta.amount1()) < params.amount1Min) {
                revert OutputAmountSlippage();
            }

            _settleDeltas(params.to, params.poolKey, delta);

            // Burn NFT
            PoolId poolId = params.poolKey.toId();
            uint256[] memory tokenIds = new uint256[](params.ids.length);
            for (uint256 i; i < params.ids.length;) {
                uint256 tokenId = poolId.toTokenId(params.ids[i]);
                _burn(params.from, tokenId, params.amounts[i]);

                tokenIds[i] = tokenId;
                unchecked {
                    ++i;
                }
            }

            return abi.encode(delta.amount0(), delta.amount1(), tokenIds);
        }
    }

    /// @notice Transfer token from user to vault. If the currency is native, assume ETH is on contract
    /// @param user If delta.amt > 0, take amt from user. else if delta.amt < 0, transfer amt to user
    function _settleDeltas(address user, PoolKey memory poolKey, BalanceDelta delta) internal {
        if (delta.amount0() > 0) {
            vault.take(poolKey.currency0, user, uint128(delta.amount0()));
        } else if (delta.amount0() < 0) {
            if (poolKey.currency0.isNative()) {
                vault.settle{value: uint256(int256(-delta.amount0()))}(poolKey.currency0);
            } else {
                vault.sync(poolKey.currency0);
                pay(poolKey.currency0, user, address(vault), uint256(int256(-delta.amount0())));
                vault.settle(poolKey.currency0);
            }
        }

        if (delta.amount1() > 0) {
            vault.take(poolKey.currency1, user, uint128(delta.amount1()));
        } else if (delta.amount1() < 0) {
            if (poolKey.currency1.isNative()) {
                vault.settle{value: uint256(int256(-delta.amount1()))}(poolKey.currency1);
            } else {
                vault.sync(poolKey.currency1);
                pay(poolKey.currency1, user, address(vault), uint256(int256(-delta.amount1())));
                vault.settle(poolKey.currency1);
            }
        }
    }
}
