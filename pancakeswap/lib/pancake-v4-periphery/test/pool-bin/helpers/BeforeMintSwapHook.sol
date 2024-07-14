// SPDX-License-Identifier: UNLICENSED

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IBinHooks} from "pancake-v4-core/src/pool-bin/interfaces/IBinHooks.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BaseBinTestHook} from "pancake-v4-core/test/pool-bin/helpers/BaseBinTestHook.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";

pragma solidity ^0.8.10;

/// @dev This hook naively always perform a swap (swapForY with 1 ether) at beforeMint()
///      Pre-req: require 1 ether of tokenIn to exist in this contract and tokenOut will stay in this contract
contract BeforeMintSwapHook is BaseBinTestHook {
    using PoolIdLibrary for PoolKey;

    struct BeforeMintCallbackData {
        PoolKey key;
        bool swapForY;
        int128 amountSpecified;
    }

    uint16 bitmap;
    IBinPoolManager public immutable binManager;
    IVault public immutable vault;

    constructor(IBinPoolManager _binManager, IVault _vault) {
        binManager = _binManager;
        vault = _vault;
    }

    function setHooksRegistrationBitmap(uint16 _bitmap) external {
        bitmap = _bitmap;
    }

    function getHooksRegistrationBitmap() external view override returns (uint16) {
        return bitmap;
    }

    /// @notice Perform a swap with the underlying pool.
    /// @dev This is POC code! Do not copy for production.
    function beforeMint(address, PoolKey calldata key, IBinPoolManager.MintParams calldata, bytes calldata)
        external
        override
        returns (bytes4)
    {
        // Swap and verify activeId did change
        if (vault.reservesOfApp(address(binManager), key.currency1) > 1 ether) {
            (uint24 activeIdBeforeSwap,,) = binManager.getSlot0(key.toId());

            // swapForY, exactInput 1 ether
            _swap(BeforeMintCallbackData(key, true, -1 ether));

            (uint24 activeIdAfterSwap,,) = binManager.getSlot0(key.toId());

            // verify activeId change
            assert(activeIdBeforeSwap != activeIdAfterSwap);
        }

        return IBinHooks.beforeMint.selector;
    }

    function _swap(BeforeMintCallbackData memory data) internal returns (bytes memory) {
        BalanceDelta delta = binManager.swap(data.key, data.swapForY, data.amountSpecified, new bytes(0));

        PoolKey memory poolKey = data.key;
        if (data.swapForY) {
            if (delta.amount0() < 0) {
                vault.sync(poolKey.currency0);
                IERC20(Currency.unwrap(poolKey.currency0)).transfer(address(vault), uint128(-delta.amount0()));
                vault.settle(poolKey.currency0);
            }
            if (delta.amount1() > 0) {
                vault.take(poolKey.currency1, address(this), uint256(int256(delta.amount1())));
            }
        } else {
            if (delta.amount1() < 0) {
                vault.sync(poolKey.currency1);
                IERC20(Currency.unwrap(poolKey.currency1)).transfer(address(vault), uint128(-delta.amount1()));
                vault.settle(poolKey.currency1);
            }
            if (delta.amount0() > 0) {
                vault.take(data.key.currency0, address(this), uint256(int256(delta.amount0())));
            }
        }

        return abi.encode(delta);
    }
}
