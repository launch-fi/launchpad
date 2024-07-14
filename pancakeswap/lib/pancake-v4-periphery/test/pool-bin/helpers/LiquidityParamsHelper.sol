// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {PriceHelper} from "pancake-v4-core/src/pool-bin/libraries/PriceHelper.sol";
import {BinHelper} from "pancake-v4-core/src/pool-bin/libraries/BinHelper.sol";
import {PackedUint128Math} from "pancake-v4-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {IBinFungiblePositionManager} from "../../../src/pool-bin/interfaces/IBinFungiblePositionManager.sol";

contract LiquidityParamsHelper {
    using SafeCast for uint256;

    /// @dev Generate list of binIds. eg. if activeId = 100, numBins = 3, it will return [99, 100, 101]
    ///      However, if numBins is even number, it will generate 1 more bin to the left, eg.
    ///      if activeId = 100, numBins = 4, return [98, 99, 100, 101]
    function getBinIds(uint24 activeId, uint8 numBins) internal pure returns (uint24[] memory binIds) {
        binIds = new uint24[](numBins);

        uint24 startId = activeId - (numBins / 2);
        for (uint256 i; i < numBins; i++) {
            binIds[i] = startId;
            startId++;
        }
    }

    /// @dev Given list of binIds and activeIds, return the delta ids.
    //       eg. given id: [100, 101, 102] and activeId: 101, return [-1, 0, 1]
    function convertToRelative(uint24[] memory absoluteIds, uint24 activeId)
        internal
        pure
        returns (int256[] memory relativeIds)
    {
        relativeIds = new int256[](absoluteIds.length);
        for (uint256 i = 0; i < absoluteIds.length; i++) {
            relativeIds[i] = int256(uint256(absoluteIds[i])) - int256(uint256(activeId));
        }
    }

    function calculateLiquidityMinted(
        bytes32 binReserves,
        uint128 amt0,
        uint128 amt1,
        uint24 binId,
        uint16 binStep,
        uint256 binTotalSupply
    ) internal pure returns (uint256 share) {
        bytes32 amountIn = PackedUint128Math.encode(amt0, amt1);
        uint256 binPrice = PriceHelper.getPriceFromId(binId, binStep);

        (share,) = BinHelper.getSharesAndEffectiveAmountsIn(binReserves, amountIn, binPrice, binTotalSupply);
    }

    /// @dev helper method to construct add liquidity param
    /// @param key pool key
    /// @param binIds list of binIds
    /// @param amountX amount of token0
    /// @param amountY amount of token1
    /// @param activeId current activeId
    /// @param recipient address to receive the liquidity
    function _getAddParams(
        PoolKey memory key,
        uint24[] memory binIds,
        uint128 amountX,
        uint128 amountY,
        uint24 activeId,
        address recipient
    ) internal view returns (IBinFungiblePositionManager.AddLiquidityParams memory params) {
        uint256 totalBins = binIds.length;

        uint8 nbBinX; // num of bins to the right
        uint8 nbBinY; // num of bins to the left
        for (uint256 i; i < totalBins; ++i) {
            if (binIds[i] >= activeId) nbBinX++;
            if (binIds[i] <= activeId) nbBinY++;
        }

        uint256[] memory distribX = new uint256[](totalBins);
        uint256[] memory distribY = new uint256[](totalBins);
        for (uint256 i; i < totalBins; ++i) {
            uint24 binId = binIds[i];
            distribX[i] = binId >= activeId ? uint256(1e18 / nbBinX).safe64() : 0;
            distribY[i] = binId <= activeId ? uint256(1e18 / nbBinY).safe64() : 0;
        }

        params = IBinFungiblePositionManager.AddLiquidityParams({
            poolKey: key,
            amount0: amountX,
            amount1: amountY,
            amount0Min: 0,
            amount1Min: 0,
            activeIdDesired: uint256(activeId),
            idSlippage: 0,
            deltaIds: convertToRelative(binIds, activeId),
            distributionX: distribX,
            distributionY: distribY,
            to: recipient,
            deadline: block.timestamp + 600
        });
    }
}
