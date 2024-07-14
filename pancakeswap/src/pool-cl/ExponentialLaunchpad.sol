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

import {CLBaseHook} from "./CLBaseHook.sol";

error SALE_IS_STILL_ONGOING();
error SALE_IS_OVER();
error AMOUNT_SPECIFIED_MUST_BE_NEGATIVE();
error PURCHASE_AMOUNT_TO_SMALL();
error DURING_SALE_PERIOD_ONLY_ALLOW_USDC_IN();
error ALREADY_PROVIDED_INITIAL_LIQUIDITY();
error INITIAL_LIQUIDITY_NOT_PROVIDED();
error PURCHASE_AMOUNT_TOO_BIG();

// launch to launch a token using usdc
contract ExponentialLaunchpad is CLBaseHook {
    using CurrencyLibrary for Currency;

    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using TickMath for int24;

    // using TickMath for
    // let's assumed the token price will grow from 0.001 USDC to 1 USDC
    // this is for the case where token_address < usdc_address
    // --> price will grow from 1e-15 to 1e-12
    // --> tick will be from -345405 (ln(1e-15) / ln(1.0001)) to -276324 (ln(1e-12) / ln(1.0001))

    // TODO: Make this customisable based on user input
    int24 internal constant MINIMUM_TICK = -345405;
    int24 internal constant MAXIMUM_TICK = -276324;

    // this is for the case where usdc_address < token_address
    // --> price will decrease exponentially from 1e15 to 1e12
    // --> tick will be from 345405 (ln(1e15)/ln(1.0001)) to 276324 (ln(1e12) / ln(1.0001))

    // TODO: Make this customisable based on user input
    int24 internal constant INVERT_MAXIMUM_TICK = 345405;
    int24 internal constant INVERT_MINIMUM_TICK = 276324;

    mapping(PoolId => uint256 mintSupply) public tokenToMintSupply;
    mapping(PoolId => uint256 tokensMinted) public mintedTokens;


    mapping(PoolId => bool) public buyDirection;
    mapping(PoolId => bool) public initialLiquidity;

    // Token address that users need to seed for launchpad
    address public immutable TOKEN_ADDRESS = address(0);

    constructor(ICLPoolManager _poolManager, address _tokenAddress) CLBaseHook(_poolManager) {
        TOKEN_ADDRESS = _tokenAddress;
    }

    modifier onlyDuringTokenSale(PoolId id) {
        if (mintedTokens[id] >= tokenToMintSupply[id]) revert SALE_IS_OVER();
        _;
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnsDelta: true,
                afterSwapReturnsDelta: false,
                afterAddLiquidityReturnsDelta: false,
                afterRemoveLiquidityReturnsDelta: false
            })
        );
    }
    
    ///////////
    // Hooks //
    ///////////

    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160,
        bytes calldata data
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        buyDirection[poolId] = Currency.unwrap(key.currency0) == TOKEN_ADDRESS;

        (uint256 maxTokenSupply) = abi.decode(data, (uint256));

        tokenToMintSupply[poolId] = maxTokenSupply;
        mintedTokens[poolId] = 0;

        return this.beforeInitialize.selector;
    }

    ///////////////////////
    // CL Pool equations //
    ///////////////////////
//    function _getAmountOut(uint256 amountIn, Currency currencyIn, Currency currencyOut) internal view returns (uint256 amountOut) {
//        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
//
//        uint256 reserveCurrencyIn = currencyIn.balanceOf(manager);
//        uint256 reserveCurrencyOut = currencyOut.balanceOf(manager);
//
//
//    }
    //////////////////////////////
    // End of CL Pool equations //
    //////////////////////////////

    function beforeSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        bool exactInput = params.amountSpecified < 0;
        (Currency specified, Currency unspecified) = getCurrencies(params, key, exactInput);

        uint256 specifiedAmount = getSpecifiedAmount(params, exactInput);
        uint256 unspecifiedAmount;
        BeforeSwapDelta returnDelta;

        if (exactInput) {
            (, unspecifiedAmount) = handleExactInputSwap(
                specifiedAmount,
                specified,
                unspecified,
                params.zeroForOne,
                key
            );

            vault.take(specified, address(this), specifiedAmount);
            vault.settle{value: unspecifiedAmount}(unspecified);

            returnDelta = toBeforeSwapDelta(specifiedAmount.toInt128(), -unspecifiedAmount.toInt128());
        } else {
            (unspecifiedAmount, ) = handleExactOutputSwap(
                specifiedAmount,
                specified,
                unspecified,
                params.zeroForOne,
                key
            );

            vault.take(unspecified, address(this), unspecifiedAmount);
            vault.settle{value: specifiedAmount}(specified);

            returnDelta = toBeforeSwapDelta(-specifiedAmount.toInt128(), unspecifiedAmount.toInt128());
        }

        return (this.beforeSwap.selector, returnDelta, 0);
    }
    //////////////////
    // End of Hooks //
    //////////////////

    function getCurrencies(
        ICLPoolManager.SwapParams calldata params,
        PoolKey calldata key,
        bool exactInput
    ) internal pure returns (Currency specified, Currency unspecified) {
        return (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
    }

    function getSpecifiedAmount(
        ICLPoolManager.SwapParams calldata params,
        bool exactInput
    ) internal pure returns (uint256) {
        return exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
    }

    function handleExactInputSwap(
        uint256 specifiedAmount,
        Currency specified,
        Currency unspecified,
        bool zeroForOne,
        PoolKey calldata key
    ) internal returns (uint256, uint256) {
        return getAmountOutFromExactInput(specifiedAmount, specified, unspecified, zeroForOne, key.toId());
    }

    function handleExactOutputSwap(
        uint256 specifiedAmount,
        Currency specified,
        Currency unspecified,
        bool zeroForOne,
        PoolKey calldata key
    ) internal returns (uint256, uint256) {
        return getAmountInForExactOutput(specifiedAmount, specified, unspecified, zeroForOne, key.toId());
    }

    function getAmountInForExactOutput(
        uint256 specifiedAmount,
        Currency specified,
        Currency unspecified,
        bool zeroForOne,
        PoolId id
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        // During sale period, only allow USDC out
        if (mintedTokens[id] < tokenToMintSupply[id]) {
            // TODO: Handle selling pressure
            if (Currency.unwrap(unspecified) != TOKEN_ADDRESS) revert DURING_SALE_PERIOD_ONLY_ALLOW_USDC_IN();

            if (zeroForOne) {
                int24 currTick = MINIMUM_TICK + int24((MAXIMUM_TICK - MINIMUM_TICK) * int256(mintedTokens[id]) / int256(tokenToMintSupply[id]));
                uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(currTick);

                // maximum value of sqrtPriceX96 is sqrt(1.0001**-276324) * 2**96 < 2**77
                // maximum value of sqrtPriceX96**2 is 2**154
                // minimum value of sqrtPriceX96**2/tokensUsedToPurchase is (1.0001**-345405 * 2**192) / (1e9 * 1e6) > 1
                uint256 inverseTokenPurchased = 2**192 / uint256(specifiedAmount);
                amountIn = (inverseTokenPurchased * uint256(specifiedAmount)) / (uint256(sqrtPriceX96) ** 2);
            } else {
                int24 currTick = INVERT_MAXIMUM_TICK - int24((INVERT_MAXIMUM_TICK - INVERT_MINIMUM_TICK) * int256(mintedTokens[id]) / int256(tokenToMintSupply[id]));
                uint256 sqrtPriceX96 = uint256(TickMath.getSqrtRatioAtTick(currTick));

                // maximum value of sqrtPriceX96**2 is 1.0001 ** 345405 * 2**192 < 2**242
                // minimum value of sqrtPriceX96**2 is 1.0001 ** 276324 * 2**192 > 2**231
                // log2(1e25) = 2**83
                // 83 + 242 - 256 = 69
                // --> need to divide the initial product by 2**100
                uint256 priceX92 = (uint256(sqrtPriceX96) ** 2) / 2**100;
                amountIn = (2**92 * uint256(specifiedAmount)) / priceX92;
            }
            amountOut = uint256(specifiedAmount);
        } else {
            if (!initialLiquidity[id]) revert INITIAL_LIQUIDITY_NOT_PROVIDED();
            amountIn = 0;
            amountOut = 0;
        }
    }

    function getAmountOutFromExactInput(
        uint256 amountSpecified,
        Currency specified,
        Currency unspecified,
        bool zeroForOne,
        PoolId id
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        // During sale period, only allow USDC in
        if (mintedTokens[id] < tokenToMintSupply[id]) {
            // TODO: Handle selling pressure
            if (Currency.unwrap(specified) != TOKEN_ADDRESS) revert DURING_SALE_PERIOD_ONLY_ALLOW_USDC_IN();

            if (zeroForOne) {
                int24 currTick = MINIMUM_TICK + int24((MAXIMUM_TICK - MINIMUM_TICK) * int256(mintedTokens[id]) / int256(tokenToMintSupply[id]));
                uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(currTick);

                // maximum value of sqrtPriceX96 is sqrt(1.0001**-276324) * 2**96 < 2**77
                // maximum value of sqrtPriceX96**2 is 2**154
                // minimum value of sqrtPriceX96**2/tokensUsedToPurchase is (1.0001**-345405 * 2**192) / (1e9 * 1e6) > 1
                uint256 inverseTokenPurchased =  (uint256(sqrtPriceX96) ** 2) / uint256(amountSpecified);
                amountOut = 2**192 / inverseTokenPurchased;
            } else {
                int24 currTick = INVERT_MAXIMUM_TICK - int24((INVERT_MAXIMUM_TICK - INVERT_MINIMUM_TICK) * int256(mintedTokens[id]) / int256(tokenToMintSupply[id]));
                uint256 sqrtPriceX96 = uint256(TickMath.getSqrtRatioAtTick(currTick));
                // maximum value of sqrtPriceX96**2 is 1.0001 ** 345405 * 2**192 < 2**242
                // minimum value of sqrtPriceX96**2 is 1.0001 ** 276324 * 2**192 > 2**231
                // log2(1e25) = 2**83
                // 83 + 242 - 256 = 69
                // --> need to divide the initial product by 2**100
                uint256 priceX92 = (uint256(sqrtPriceX96) ** 2) / 2**100;
                amountOut = priceX92 * amountSpecified / 2**92;
            }

            amountIn = uint256(amountSpecified);

            // Ideally, we want to mint the exact amount of tokens, then refund the remaining amount not used to the user
            mintedTokens[id] += amountOut;
        } else {
            if (!initialLiquidity[id]) revert INITIAL_LIQUIDITY_NOT_PROVIDED();
            amountIn = 0;
            amountOut = 0;
        }
    }
}