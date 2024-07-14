pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SD59x18, sd} from "@prb/math/src/SD59x18.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import "forge-std/console.sol";

error INVALID_PAYMENT_TOKEN();
error INVALID_AMOUNT_SPECIFIED();
error INVALID_PARAMETERS();
error INSUFFICIENT_AVAILABLE_TOKENS();
error INVALID_DIRECTION();

contract DutchAuctionLaunchPad is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using CurrencySettler for Currency;

    mapping(PoolId => SD59x18) public salePeriod; 
    mapping(PoolId => int256) public tokenSupplyLeft;
    mapping(PoolId => SD59x18) public initialPrice; 
    mapping(PoolId => SD59x18) public decayConstant; 
    mapping(PoolId => SD59x18) public emissionRate;
    mapping(PoolId => SD59x18) public lastAvailableAuctionStartTime;
    mapping(PoolId => address) public paymentToken;
    mapping(PoolId => address) public tokenToSell;
    mapping(PoolId => bool) public auctionOver;

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false, // -- disable v4 liquidity with a revert -- //
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // -- Custom Curve Handler --  //
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // -- Enables Custom Curves --  //
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
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
            key.currency1.settle(manager, _liquidityInitializer, uint256(_initialTokenSupply), false);
            key.currency1.take(manager, address(this), uint256(_initialTokenSupply), true);
        } else if ( Currency.unwrap(key.currency1)==_paymentToken) {      
            paymentToken[poolId] = Currency.unwrap(key.currency1);
            tokenToSell[poolId] = Currency.unwrap(key.currency0);
            key.currency0.settle(manager, _liquidityInitializer, uint256(_initialTokenSupply), false);
            key.currency0.take(manager, address(this), uint256(_initialTokenSupply), true);
        } else revert INVALID_PAYMENT_TOKEN();
        return DutchAuctionLaunchPad.beforeInitialize.selector;
    }

    function beforeSwap(
        address, 
        PoolKey calldata key, 
        IPoolManager.SwapParams calldata params,
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
            Currency.wrap(paymentToken[poolId]).take(manager, address(this), unspecifiedAmount, true);
            Currency.wrap(tokenToSell[poolId]).settle(manager, address(this), uint256(params.amountSpecified), true);
            returnDelta = toBeforeSwapDelta(-(uint256(params.amountSpecified).toInt128()), unspecifiedAmount.toInt128());
            if (tokenSupplyLeft[poolId] == 0) {
                auctionOver[poolId] = true;
            }
            lastAvailableAuctionStartTime[poolId] = lastAvailableAuctionStartTime[poolId] + secondsOfEmissionsToPurchase;
        }

        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }
}