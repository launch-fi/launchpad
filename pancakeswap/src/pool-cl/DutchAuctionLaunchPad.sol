pragma solidity ^0.8.24;

import {IERC20Minimal} from "@pancakeswap/v4-core/src/interfaces/IERC20Minimal.sol";
import {FullMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/FullMath.sol";
import {TickMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@pancakeswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta} from "@pancakeswap/v4-core/src/types/BeforeSwapDelta.sol";
import {toBeforeSwapDelta} from "@pancakeswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ICLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {SafeCast} from "@pancakeswap/v4-core/src/libraries/SafeCast.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";
import {SD59x18, sd} from "@prb/math/src/SD59x18.sol";

import {CLBaseHook} from "./CLBaseHook.sol";

import "forge-std/console.sol";

error INVALID_PAYMENT_TOKEN();
error INVALID_AMOUNT_SPECIFIED();
error INVALID_PARAMETERS();
error INSUFFICIENT_AVAILABLE_TOKENS();
error INVALID_DIRECTION();

contract DutchAuctionLaunchPad is CLBaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    mapping(PoolId => SD59x18) public salePeriod; 
    mapping(PoolId => int256) public tokenSupplyLeft;
    mapping(PoolId => SD59x18) public initialPrice; 
    mapping(PoolId => SD59x18) public decayConstant; 
    mapping(PoolId => SD59x18) public emissionRate;
    mapping(PoolId => SD59x18) public lastAvailableAuctionStartTime;
    mapping(PoolId => address) public paymentToken;
    mapping(PoolId => address) public tokenToSell;
    mapping(PoolId => bool) public auctionOver;

    constructor(ICLPoolManager poolManager) CLBaseHook(poolManager) {}
    
    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false, // -- disable v4 liquidity with a revert -- //
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, // -- Custom Curve Handler --  //
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnsDelta: true, // -- Enables Custom Curves --  //
                afterSwapReturnsDelta: false,
                afterAddLiquidityReturnsDelta: false,
                afterRemoveLiquidityReturnsDelta: false
            })
        );
    }

    function beforeInitialize(
        address, 
        PoolKey calldata key, 
        uint160, 
        bytes calldata data
    ) external override returns(bytes4) { 
        PoolId poolId = key.toId();
        address _liquidityInitializer;
        int256 _initialTokenSupply;
        address _paymentToken;
        {
            (int256 _salePeriod, 
            int256 __initialTokenSupply, 
            int256 _initialPrice, 
            int256 _decayConstant, 
            int256 _emissionRate, 
            address __paymentToken, 
            address __liquidityInitializer) 
            = abi.decode(data, (int256, int256, int256, int256, int256, address, address));
            if (_salePeriod < 0 || _initialTokenSupply < 0 || _initialPrice < 0 || _decayConstant < 0 || _emissionRate < 0) revert INVALID_PARAMETERS();
            lastAvailableAuctionStartTime[poolId] = sd(int256(block.timestamp) * 1e18);
            salePeriod[poolId] = sd(_salePeriod * 1e18);
            tokenSupplyLeft[poolId] = __initialTokenSupply;
            initialPrice[poolId] = sd(_initialPrice * 1e18);
            decayConstant[poolId] = sd(_decayConstant * 1e18);
            emissionRate[poolId] = sd(_emissionRate * 1e18);
            paymentToken[poolId] = __paymentToken;
            _liquidityInitializer = __liquidityInitializer;
            _initialTokenSupply = __initialTokenSupply;
            _paymentToken   = __paymentToken;
        }
        if (Currency.unwrap(key.currency0)==_paymentToken) {
            paymentToken[poolId] = Currency.unwrap(key.currency0);
            tokenToSell[poolId] = Currency.unwrap(key.currency1);

            vault.settle {value: uint256(_initialTokenSupply)}(key.currency1);
            vault.take(key.currency1, address(this), uint256(_initialTokenSupply));

        } else if ( Currency.unwrap(key.currency1)==_paymentToken) {      
            paymentToken[poolId] = Currency.unwrap(key.currency1);
            tokenToSell[poolId] = Currency.unwrap(key.currency0);

            vault.settle {value: uint256(_initialTokenSupply)}(key.currency0);
            vault.take(key.currency0, address(this), uint256(_initialTokenSupply));
        } else revert INVALID_PAYMENT_TOKEN();
        return DutchAuctionLaunchPad.beforeInitialize.selector;
    }

    function beforeSwap(
        address, 
        PoolKey calldata key, 
        ICLPoolManager.SwapParams calldata params,
        bytes calldata data
    ) external override returns(bytes4, BeforeSwapDelta, uint24) {
        address swapper = abi.decode(data, (address));
        PoolId poolId = key.toId();
        BeforeSwapDelta returnDelta;
        if (sd(int256(block.timestamp)  * 1e18) > lastAvailableAuctionStartTime[poolId] + salePeriod[poolId]) 
        {
            auctionOver[poolId] = true;
        }
        if (auctionOver[poolId]) {
            // execute swap like the normal case
        } else {
            // we expect exactOutput, the calculation is done offchain
            if (params.amountSpecified < 0) {
                revert INVALID_AMOUNT_SPECIFIED();
            }
            if (params.zeroForOne != (paymentToken[poolId]==Currency.unwrap(key.currency0))) {
                revert INVALID_DIRECTION();
            }
            tokenSupplyLeft[poolId] -= params.amountSpecified; 
            if (tokenSupplyLeft[poolId] < 0) {
                // tokenSupplyLeft[poolId] += params.amountSpecified;
                // params.amountSpecified = tokenSupplyLeft[poolId];
                // tokenSupplyLeft[poolId] = 0;
                revert INSUFFICIENT_AVAILABLE_TOKENS();
            }
            uint256 unspecifiedAmount;

            SD59x18 secondsOfEmissionsAvailable = sd(int256(block.timestamp) * 1e18) - lastAvailableAuctionStartTime[poolId];
            SD59x18 secondsOfEmissionsToPurchase = sd(int256(params.amountSpecified) * 1e18).div(emissionRate[poolId]);
            console.logInt(SD59x18.unwrap(secondsOfEmissionsToPurchase));
            console.logInt(SD59x18.unwrap(secondsOfEmissionsAvailable));
            if (secondsOfEmissionsToPurchase > secondsOfEmissionsAvailable) {
                revert INSUFFICIENT_AVAILABLE_TOKENS();
            }
            {
                // avoid stack too deep
                PoolId copyPoolId = poolId;
                SD59x18 quantity = sd(int256(params.amountSpecified) * 1e18);
                SD59x18 timeSinceLastAuctionStart = sd(int256(block.timestamp) * 1e18) - lastAvailableAuctionStartTime[copyPoolId];
                SD59x18 num1 = initialPrice[copyPoolId].div(decayConstant[copyPoolId]);
                SD59x18 num2 = decayConstant[copyPoolId].mul(quantity).div(emissionRate[copyPoolId]).exp() - sd(1e18);
                SD59x18 den = decayConstant[copyPoolId].mul(timeSinceLastAuctionStart).exp();
                SD59x18 totalCost = num1.mul(num2).div(den);
                unspecifiedAmount =uint256(SD59x18.unwrap(totalCost) / 1e18);
            }
            // take and settle here
            vault.take(Currency.wrap(paymentToken[poolId]), address(this), unspecifiedAmount);
            vault.settle {value: uint256(params.amountSpecified)}(Currency.wrap(tokenToSell[poolId]));
            returnDelta = toBeforeSwapDelta(-(uint256(params.amountSpecified).toInt128()), unspecifiedAmount.toInt128());
            if (tokenSupplyLeft[poolId] == 0) {
                auctionOver[poolId] = true;
            }
            lastAvailableAuctionStartTime[poolId] = lastAvailableAuctionStartTime[poolId] + secondsOfEmissionsToPurchase;
        }

        return (CLBaseHook.beforeSwap.selector, returnDelta, 0);
    }
}