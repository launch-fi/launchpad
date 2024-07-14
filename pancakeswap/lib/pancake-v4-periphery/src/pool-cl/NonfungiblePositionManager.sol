// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {CLPosition} from "pancake-v4-core/src/pool-cl/libraries/CLPosition.sol";
import {BalanceDelta, toBalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {FixedPoint128} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint128.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";

import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {INonfungibleTokenPositionDescriptor} from "./interfaces/INonfungibleTokenPositionDescriptor.sol";
import {ERC721Permit} from "./base/ERC721Permit.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {PeripheryValidation} from "../base/PeripheryValidation.sol";
import {SelfPermit} from "../base/SelfPermit.sol";
import {LiquidityManagement} from "./base/LiquidityManagement.sol";
import {CLPeripheryImmutableState} from "./base/CLPeripheryImmutableState.sol";
import {Multicall} from "../base/Multicall.sol";

/// @title NFT positions
/// @notice Wraps Pancake V4 positions in the ERC721 non-fungible token interface
contract NonfungiblePositionManager is
    INonfungiblePositionManager,
    ERC721Permit,
    PeripheryValidation,
    LiquidityManagement,
    SelfPermit,
    Multicall
{
    using PoolIdLibrary for PoolKey;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 private _nextId = 1;

    /// @dev Pool keys by poolIds, so we don't save the same poolKey multiple times
    mapping(PoolId pooId => PoolKey) private _poolIdToPoolKey;

    /// @dev The token ID position data
    mapping(uint256 tokenId => Position) private _positions;

    /// @dev The address of the token descriptor contract, which handles generating token URIs for position tokens
    address private immutable _tokenDescriptor;

    constructor(IVault _vault, ICLPoolManager _poolManager, address _tokenDescriptor_, address _WETH9)
        CLPeripheryImmutableState(_vault, _poolManager, _WETH9)
        ERC721Permit("Pancake V4 Positions NFT-V1", "PCS-V4-POS", "1")
    {
        _tokenDescriptor = _tokenDescriptor_;
    }

    modifier isAuthorizedForToken(uint256 tokenId) {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) {
            revert NotOwnerOrOperator();
        }
        _;
    }

    /// @inheritdoc INonfungiblePositionManager
    function positions(uint256 tokenId)
        external
        view
        override
        returns (
            uint96 nonce,
            address operator,
            Currency currency0,
            Currency currency1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
            bytes32 salt
        )
    {
        Position memory position = _positions[tokenId];
        if (PoolId.unwrap(position.poolId) == 0) revert InvalidTokenID();
        PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        return (
            position.nonce,
            position.operator,
            poolKey.currency0,
            poolKey.currency1,
            poolKey.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.tokensOwed0,
            position.tokensOwed1,
            position.salt
        );
    }

    /// @inheritdoc INonfungiblePositionManager
    function initialize(PoolKey memory poolKey, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        payable
        override
        returns (int24 tick)
    {
        (tick) = poolManager.initialize(poolKey, sqrtPriceX96, hookData);
    }

    /// @inheritdoc INonfungiblePositionManager
    function mint(MintParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // msg.sender as payer, params.recipient as NFT position receiver
        (tokenId, liquidity, amount0, amount1) = abi.decode(
            vault.lock(abi.encode(CallbackData(msg.sender, CallbackDataType.Mint, abi.encode(params)))),
            (uint256, uint128, uint256, uint256)
        );

        emit IncreaseLiquidity(tokenId, liquidity, amount0, amount1);
    }

    /// @inheritdoc INonfungiblePositionManager
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (liquidity, amount0, amount1) = abi.decode(
            vault.lock(abi.encode(CallbackData(msg.sender, CallbackDataType.IncreaseLiquidity, abi.encode(params)))),
            (uint128, uint256, uint256)
        );

        emit IncreaseLiquidity(params.tokenId, liquidity, amount0, amount1);
    }

    /// @inheritdoc INonfungiblePositionManager
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        override
        isAuthorizedForToken(params.tokenId)
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        if (params.liquidity == 0) {
            revert InvalidLiquidityDecreaseAmount();
        }
        (amount0, amount1) = abi.decode(
            vault.lock(abi.encode(CallbackData(msg.sender, CallbackDataType.DecreaseLiquidity, abi.encode(params)))),
            (uint256, uint256)
        );

        emit DecreaseLiquidity(params.tokenId, params.liquidity, amount0, amount1);
    }

    /// @inheritdoc INonfungiblePositionManager
    function burn(uint256 tokenId) external payable override isAuthorizedForToken(tokenId) {
        Position storage position = _positions[tokenId];
        if (position.liquidity > 0 || position.tokensOwed0 > 0 || position.tokensOwed1 > 0) {
            revert NonEmptyPosition();
        }

        delete _positions[tokenId];
        _burn(tokenId);
    }

    /// @inheritdoc INonfungiblePositionManager
    function collect(CollectParams memory params)
        external
        payable
        override
        isAuthorizedForToken(params.tokenId)
        returns (uint256 amount0, uint256 amount1)
    {
        if (params.amount0Max == 0 && params.amount1Max == 0) {
            revert InvalidMaxCollectAmount();
        }
        params.recipient = params.recipient == address(0) ? address(msg.sender) : params.recipient;

        (amount0, amount1) = abi.decode(
            vault.lock(abi.encode(CallbackData(msg.sender, CallbackDataType.Collect, abi.encode(params)))),
            (uint256, uint256)
        );

        emit Collect(params.tokenId, params.recipient, amount0, amount1);
    }

    function lockAcquired(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(vault)) {
            revert OnlyVaultCaller();
        }

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        if (data.callbackDataType == CallbackDataType.Mint) {
            return _handleMint(data);
        } else if (data.callbackDataType == CallbackDataType.IncreaseLiquidity) {
            return _handleIncreaseLiquidity(data);
        } else if (data.callbackDataType == CallbackDataType.DecreaseLiquidity) {
            return _handleDecreaseLiquidity(data);
        } else if (data.callbackDataType == CallbackDataType.Collect) {
            return _handleCollect(data);
        } else {
            revert InvalidCalldataType();
        }
    }

    function _handleMint(CallbackData memory data) internal returns (bytes memory) {
        INonfungiblePositionManager.MintParams memory params =
            abi.decode(data.params, (INonfungiblePositionManager.MintParams));

        (uint128 liquidity, BalanceDelta delta) = addLiquidity(
            AddLiquidityParams({
                poolKey: params.poolKey,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                salt: params.salt,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min
            })
        );

        uint256 tokenId = _nextId++;
        _mint(params.recipient, tokenId);

        CLPosition.Info memory positionInfo = poolManager.getPosition(
            params.poolKey.toId(), address(this), params.tickLower, params.tickUpper, params.salt
        );
        _positions[tokenId] = Position({
            nonce: 0,
            operator: address(0),
            poolId: params.poolKey.toId(),
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: positionInfo.feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: positionInfo.feeGrowthInside1LastX128,
            tokensOwed0: 0,
            tokensOwed1: 0,
            salt: params.salt
        });
        if (address(_poolIdToPoolKey[params.poolKey.toId()].poolManager) == address(0)) {
            _poolIdToPoolKey[params.poolKey.toId()] = params.poolKey;
        }

        settleDeltas(data.sender, params.poolKey, delta);

        return abi.encode(tokenId, liquidity, -delta.amount0(), -delta.amount1());
    }

    function _handleIncreaseLiquidity(CallbackData memory data) internal returns (bytes memory) {
        IncreaseLiquidityParams memory params = abi.decode(data.params, (IncreaseLiquidityParams));
        Position storage nftPosition = _positions[params.tokenId];
        PoolId poolId = nftPosition.poolId;
        uint128 existingLiquility = nftPosition.liquidity;
        int24 tickLower = nftPosition.tickLower;
        int24 tickUpper = nftPosition.tickUpper;
        bytes32 salt = nftPosition.salt;
        PoolKey memory poolKey = _poolIdToPoolKey[poolId];

        (uint128 liquidity, BalanceDelta delta) = addLiquidity(
            AddLiquidityParams({
                poolKey: poolKey,
                tickLower: tickLower,
                tickUpper: tickUpper,
                salt: salt,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min
            })
        );

        CLPosition.Info memory poolManagerPositionInfo =
            poolManager.getPosition(poolId, address(this), tickLower, tickUpper, salt);

        /// @dev This can be overflow in following cases:
        /// 1. feeGrowthInside0LastX128 is overflow
        /// 2. when we add liquidity to a empty position:
        ///     poolManagerPositionInfo.feeGrowthInside0LastX128 = 0
        ///     however nftPosition.feeGrowthInside0LastX128 could be greater than 0
        ///     because clPoolManager will reset ticks if liquidity is back to 0
        ///     but feeGrowthInside0LastX128 will not be reset
        ///     that's won't cause any issue because existingLiquility = 0
        ///     unchecked is needed to avoid overflow error
        unchecked {
            nftPosition.tokensOwed0 += uint128(
                FullMath.mulDiv(
                    poolManagerPositionInfo.feeGrowthInside0LastX128 - nftPosition.feeGrowthInside0LastX128,
                    existingLiquility,
                    FixedPoint128.Q128
                )
            );
            nftPosition.tokensOwed1 += uint128(
                FullMath.mulDiv(
                    poolManagerPositionInfo.feeGrowthInside1LastX128 - nftPosition.feeGrowthInside1LastX128,
                    existingLiquility,
                    FixedPoint128.Q128
                )
            );
        }

        nftPosition.feeGrowthInside0LastX128 = poolManagerPositionInfo.feeGrowthInside0LastX128;
        nftPosition.feeGrowthInside1LastX128 = poolManagerPositionInfo.feeGrowthInside1LastX128;
        nftPosition.liquidity += liquidity;

        settleDeltas(data.sender, poolKey, delta);

        return abi.encode(liquidity, -delta.amount0(), -delta.amount1());
    }

    function _handleDecreaseLiquidity(CallbackData memory data) internal returns (bytes memory) {
        DecreaseLiquidityParams memory params = abi.decode(data.params, (DecreaseLiquidityParams));
        Position storage nftPosition = _positions[params.tokenId];
        PoolId poolId = nftPosition.poolId;
        uint128 liquidity = nftPosition.liquidity;
        int24 tickLower = nftPosition.tickLower;
        int24 tickUpper = nftPosition.tickUpper;
        bytes32 salt = nftPosition.salt;
        PoolKey memory poolKey = _poolIdToPoolKey[poolId];

        if (liquidity < params.liquidity) {
            revert InvalidLiquidityDecreaseAmount();
        }

        BalanceDelta delta = removeLiquidity(
            RemoveLiquidityParams({
                poolKey: poolKey,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: params.liquidity,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                salt: salt
            })
        );

        CLPosition.Info memory poolManagerPositionInfo =
            poolManager.getPosition(poolId, address(this), tickLower, tickUpper, salt);

        /// @dev This can be overflow in following cases:
        /// 1. feeGrowthInside0LastX128 is overflow
        /// 2. when we add liquidity to a empty position:
        ///     poolManagerPositionInfo.feeGrowthInside0LastX128 = 0
        ///     however nftPosition.feeGrowthInside0LastX128 could be greater than 0
        ///     because clPoolManager will reset ticks if liquidity is back to 0
        ///     but feeGrowthInside0LastX128 will not be reset
        ///     that's won't cause any issue because existingLiquility = 0
        ///     unchecked is needed to avoid overflow error
        unchecked {
            nftPosition.tokensOwed0 += uint128(
                FullMath.mulDiv(
                    poolManagerPositionInfo.feeGrowthInside0LastX128 - nftPosition.feeGrowthInside0LastX128,
                    liquidity,
                    FixedPoint128.Q128
                )
            );

            nftPosition.tokensOwed1 += uint128(
                FullMath.mulDiv(
                    poolManagerPositionInfo.feeGrowthInside1LastX128 - nftPosition.feeGrowthInside1LastX128,
                    liquidity,
                    FixedPoint128.Q128
                )
            );
        }

        nftPosition.feeGrowthInside0LastX128 = poolManagerPositionInfo.feeGrowthInside0LastX128;
        nftPosition.feeGrowthInside1LastX128 = poolManagerPositionInfo.feeGrowthInside1LastX128;
        unchecked {
            nftPosition.liquidity -= params.liquidity;
        }

        settleDeltas(data.sender, poolKey, delta);

        return abi.encode(delta.amount0(), delta.amount1());
    }

    function _handleCollect(CallbackData memory data) internal returns (bytes memory) {
        CollectParams memory params = abi.decode(data.params, (CollectParams));
        Position storage nftPosition = _positions[params.tokenId];
        Position memory nftPositionCache = _positions[params.tokenId];
        PoolId poolId = nftPositionCache.poolId;
        bytes32 salt = nftPositionCache.salt;
        PoolKey memory poolKey = _poolIdToPoolKey[poolId];

        uint128 tokensOwed0 = nftPositionCache.tokensOwed0;
        uint128 tokensOwed1 = nftPositionCache.tokensOwed1;

        if (nftPositionCache.liquidity > 0) {
            mintAccumulatedPositionFee(poolKey, nftPositionCache.tickLower, nftPositionCache.tickUpper, salt);

            CLPosition.Info memory poolManagerPositionInfo = poolManager.getPosition(
                poolId, address(this), nftPositionCache.tickLower, nftPositionCache.tickUpper, salt
            );

            /// @dev This can be overflow in following cases:
            /// 1. feeGrowthInside0LastX128 is overflow
            /// 2. when we add liquidity to a empty position:
            ///     poolManagerPositionInfo.feeGrowthInside0LastX128 = 0
            ///     however nftPosition.feeGrowthInside0LastX128 could be greater than 0
            ///     because clPoolManager will reset ticks if liquidity is back to 0
            ///     but feeGrowthInside0LastX128 will not be reset
            ///     that's won't cause any issue because existingLiquility = 0
            ///     unchecked is needed to avoid overflow error
            unchecked {
                tokensOwed0 += uint128(
                    FullMath.mulDiv(
                        poolManagerPositionInfo.feeGrowthInside0LastX128 - nftPositionCache.feeGrowthInside0LastX128,
                        nftPositionCache.liquidity,
                        FixedPoint128.Q128
                    )
                );
                tokensOwed1 += uint128(
                    FullMath.mulDiv(
                        poolManagerPositionInfo.feeGrowthInside1LastX128 - nftPositionCache.feeGrowthInside1LastX128,
                        nftPositionCache.liquidity,
                        FixedPoint128.Q128
                    )
                );
            }

            nftPosition.feeGrowthInside0LastX128 = poolManagerPositionInfo.feeGrowthInside0LastX128;
            nftPosition.feeGrowthInside1LastX128 = poolManagerPositionInfo.feeGrowthInside1LastX128;
        }

        (uint128 amount0Collect, uint128 amount1Collect) = (
            params.amount0Max > tokensOwed0 ? tokensOwed0 : params.amount0Max,
            params.amount1Max > tokensOwed1 ? tokensOwed1 : params.amount1Max
        );

        // update position
        nftPosition.tokensOwed0 = tokensOwed0 - amount0Collect;
        nftPosition.tokensOwed1 = tokensOwed1 - amount1Collect;

        /// @dev due to rounding down calculation in FullMath, some wei might be loss if the fee is too small
        /// if that happen we need to ignore the loss part and take the rest of the fee otherwise it will revert whole tx
        uint128 actualFee0Left = uint128(vault.balanceOf(address(this), poolKey.currency0));
        uint128 actualFee1Left = uint128(vault.balanceOf(address(this), poolKey.currency1));
        (amount0Collect, amount1Collect) = (
            actualFee0Left > amount0Collect ? amount0Collect : actualFee0Left,
            actualFee1Left > amount1Collect ? amount1Collect : actualFee1Left
        );

        // cash out from vault
        burnAndTake(poolKey.currency0, params.recipient, amount0Collect);
        burnAndTake(poolKey.currency1, params.recipient, amount1Collect);

        return abi.encode(amount0Collect, amount1Collect);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, IERC721Metadata) returns (string memory) {
        if (!_exists(tokenId)) {
            revert NonexistentToken();
        }

        return INonfungibleTokenPositionDescriptor(_tokenDescriptor).tokenURI(this, tokenId);
    }

    // TODO: double check when update solidity version & oz version
    // Different oz version might have different inner implementation for approving part
    function _getAndIncrementNonce(uint256 tokenId) internal override returns (uint256) {
        return uint256(_positions[tokenId].nonce++);
    }

    /// @inheritdoc IERC721
    function getApproved(uint256 tokenId) public view override(ERC721, IERC721) returns (address) {
        if (!_exists(tokenId)) {
            revert NonexistentToken();
        }

        return _positions[tokenId].operator;
    }

    /// @dev Overrides _approve to use the operator in the position, which is packed with the position permit nonce
    function _approve(address to, uint256 tokenId) internal override(ERC721) {
        _positions[tokenId].operator = to;
        emit Approval(ownerOf(tokenId), to, tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal override(ERC721) {
        // Clear approvals from the previous owner
        _positions[tokenId].operator = address(0);
        super._transfer(from, to, tokenId);
    }
}
