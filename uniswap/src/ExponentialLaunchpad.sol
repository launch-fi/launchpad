pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import { console } from "forge-std/console.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {UniswapV4ERC20} from "./UniswapV4ERC20.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

    error SALE_IS_STILL_ONGOING();
    error SALE_IS_OVER();
    error AMOUNT_SPECIFIED_MUST_BE_NEGATIVE();
    error PURCHASE_AMOUNT_TO_SMALL();
    error DURING_SALE_PERIOD_ONLY_ALLOW_USDC_IN();
    error ALREADY_PROVIDED_INITIAL_LIQUIDITY();
    error INITIAL_LIQUIDITY_NOT_PROVIDED();
    error PURCHASE_AMOUNT_TOO_BIG();
    error SENDER_MUST_BE_HOOK();
    error POOL_NOT_INITIALIZED();
    error TOO_MUCH_SLIPPAGE();

// launch to launch a token using usdc
contract ExponentialLaunchpad is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using TickMath for int24;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

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

    // TODO: Make this customisable based on user input
    uint256 public constant INITIAL_FEE = 100000; // 10% in basis points
    uint256 public constant DECAY_DURATION = 10 days;

    mapping(PoolId => uint256 mintSupply) public tokenToMintSupply;
    mapping(PoolId => uint256 tokensMinted) public mintedTokens;
    mapping(PoolId => address poolToken) public poolLpToken;
    mapping(PoolId => uint256 clStartTime) public poolToLPStartTime;
    mapping(PoolId => uint24 dynamicLpFee) public poolDynamicFees;
    mapping(PoolId => bool) public buyDirection;

    // Token address that users need to seed for launchpad
    address public immutable TOKEN_ADDRESS = address(0);

    constructor(IPoolManager _poolManager, address _tokenAddress) BaseHook(_poolManager) {
        TOKEN_ADDRESS = _tokenAddress;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    struct AddLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address to;
        uint256 deadline;
    }

    struct RemoveLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 liquidity;
        uint256 deadline;
    }


    modifier onlyDuringTokenSale(PoolId id) {
        if (mintedTokens[id] >= tokenToMintSupply[id]) revert SALE_IS_OVER();
        _;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(manager));
        _;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // -- Custom Curve Handler --  //
            afterSwap: true, // -- Seed initial liquidity -- //
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // -- Enables Custom Curves --  //
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    ///////////
    // Hooks //
    ///////////

    function beforeInitialize(
        address _initializer,
        PoolKey calldata key,
        uint160,
        bytes calldata data
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        (uint256 maxTokenSupply) = abi.decode(data, (uint256));
        buyDirection[poolId] = Currency.unwrap(key.currency0) == TOKEN_ADDRESS;

        // send tokens to the pool manager
        if (buyDirection[poolId]) {
            key.currency1.settle(manager, _initializer, maxTokenSupply, false);
            key.currency1.take(manager, address(this), maxTokenSupply, true);
        } else {
            key.currency0.settle(manager, _initializer, maxTokenSupply, false);
            key.currency0.take(manager, address(this), maxTokenSupply, true);
        }


        tokenToMintSupply[poolId] = maxTokenSupply;
        mintedTokens[poolId] = 0;
        // Deploy ERC20 LP token
        address poolToken = address(new UniswapV4ERC20("MEME", "MEME"));
        poolLpToken[poolId] = poolToken;
        poolLpToken[poolId] = poolToken;
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
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external onlyPoolManager override returns (bytes4, BeforeSwapDelta, uint24) {
        bool exactInput = params.amountSpecified < 0;
        (Currency specified, Currency unspecified) = getCurrencies(params, key, exactInput);

        uint256 specifiedAmount = getSpecifiedAmount(params, exactInput);

        PoolId id = key.toId();
        uint256 lpStartTime = poolToLPStartTime[id];

        punishDumpers(exactInput, Currency.unwrap(specified), key);

        if (exactInput) {
            return handleExactInput(params, key, specified, unspecified, specifiedAmount);
        } else {
            return handleExactOutput(params, key, specified, unspecified, specifiedAmount);
        }
    }

    function punishDumpers(bool exactInput, address specified, PoolKey calldata key) internal {
        if (exactInput) {
            // Check input is NOT TOKEN_ADDRESS (buying action)
            if (specified == TOKEN_ADDRESS) {
                uint24 fee = calculateDynamicLpFee(key.toId());
                poolDynamicFees[key.toId()] = fee;
                manager.updateDynamicLPFee(key, fee);
            }
        } else {
            // Check output is TOKEN_ADDRESS (selling action)
            if (specified != TOKEN_ADDRESS) {
                uint24 fee = calculateDynamicLpFee(key.toId());
                poolDynamicFees[key.toId()] = fee;
                manager.updateDynamicLPFee(key, fee);
            }
        }
    }

    function getFee(
        PoolKey calldata key
    ) external view returns (uint24) {
        uint24 currentDynamicLpFee = poolDynamicFees[key.toId()];
        return currentDynamicLpFee;
    }

    function handleExactInput(
        IPoolManager.SwapParams calldata params,
        PoolKey calldata key,
        Currency specified,
        Currency unspecified,
        uint256 specifiedAmount
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 unspecifiedAmount;
        BeforeSwapDelta returnDelta;

        // because we may need to change the inputAmount if the input is too large
        (specifiedAmount, unspecifiedAmount) = handleExactInputSwap(
            specifiedAmount,
            specified,
            unspecified,
            params.zeroForOne,
            key
        );

        specified.take(manager, address(this), specifiedAmount, true);
        unspecified.settle(manager, address(this), unspecifiedAmount, true);
        returnDelta = toBeforeSwapDelta(specifiedAmount.toInt128(), -unspecifiedAmount.toInt128());

        return (this.beforeSwap.selector, returnDelta, 0);
    }

    function handleExactOutput(
        IPoolManager.SwapParams calldata params,
        PoolKey calldata key,
        Currency specified,
        Currency unspecified,
        uint256 specifiedAmount
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 unspecifiedAmount;
        BeforeSwapDelta returnDelta;

        (unspecifiedAmount, ) = handleExactOutputSwap(
            specifiedAmount,
            specified,
            unspecified,
            params.zeroForOne,
            key
        );

        unspecified.take(manager, address(this), unspecifiedAmount, true);
        specified.settle(manager, address(this), specifiedAmount, true);
        returnDelta = toBeforeSwapDelta(-specifiedAmount.toInt128(), unspecifiedAmount.toInt128());

        return (this.beforeSwap.selector, returnDelta, 0);
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
    external
    override
    returns (bytes4, int128) {
        seedInitialLiquidity(key);
        return (this.afterSwap.selector, 0);
    }


    //////////////////
    // End of Hooks //
    //////////////////


    //////////////////
    // Dynamic fees //
    //////////////////

    function calculateDynamicLpFee(PoolId id) internal view returns (uint24) {
        UD60x18 elapsedTime = ud(block.timestamp).sub(ud(poolToLPStartTime[id]));
        if (elapsedTime >= ud(DECAY_DURATION)) {
            return 0;
        }

        // Scaled by 1e18
        UD60x18 normalizedTime = (ud(DECAY_DURATION).sub(elapsedTime)).div(ud(DECAY_DURATION));

        // Linear decay
        UD60x18 currentFeeUd = normalizedTime.mul(ud(INITIAL_FEE)).div(ud(1e18));

        // Convert the fee to uint256 by rounding down
        uint40 feeX40 = currentFeeUd.intoUint40();

        return uint24(feeX40);
    }

    function seedInitialLiquidity(PoolKey calldata key) internal {
        PoolId id = key.toId();

        if (mintedTokens[id] >= tokenToMintSupply[id]) {
            // Seed liquidity to pool for currency0, currency1
            if (poolToLPStartTime[id] == 0) {
                // Deploy ERC20 LP token
                address poolToken = address(new UniswapV4ERC20("MEME", "MEME"));
                poolLpToken[id] = poolToken;

                // Replace with actual token address
                UniswapV4ERC20(poolToken).mint(address(this), 10_000 ether);

                uint128 liquidityBefore = manager.getPosition(
                    id, address(this), TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), 0
                ).liquidity;
                int256 delta0;
                int256 delta1;
                {
                    int deltaBefore0 = manager.currencyDelta(address(this), key.currency0);
                    int deltaBefore1 = manager.currencyDelta(address(this), key.currency1);

                    (BalanceDelta callerDelta, ) =  manager.modifyLiquidity(
                        key,
                        IPoolManager.ModifyLiquidityParams({
                            tickLower: TickMath.minUsableTick(key.tickSpacing),
                            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                            liquidityDelta: 0.01 ether,
                            salt: 0
                        }),
                        ""
                    );

                    uint128 liquidityAfter = manager.getPosition(
                        id, address(this), TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), 0
                    ).liquidity;


                    int deltaAfter0 = manager.currencyDelta(address(this), key.currency0);
                    int deltaAfter1 = manager.currencyDelta(address(this), key.currency1);
                    delta0 = deltaAfter0 - deltaBefore0;
                    delta1 = deltaAfter1 - deltaBefore1;
                    require(
                        int128(liquidityBefore) + 0.01 ether == int128(liquidityAfter), "liquidity change incorrect"
                    );
                }

                if (delta0 < 0) key.currency0.settle(manager, address(this), uint256(-delta0), false);
                if (delta1 < 0) key.currency1.settle(manager, address(this), uint256(-delta1), false);
                if (delta0 > 0) key.currency0.take(manager, address(this), uint256(delta0), false);
                if (delta1 > 0) key.currency1.take(manager, address(this), uint256(delta1), false);

                // Add liquidity to pool
                poolToLPStartTime[id] = block.timestamp;

                // Replace with actual token address
                UniswapV4ERC20(poolLpToken[id]).mint(address(this), 0.01 ether);
            }
        }
    }

    function _unlockCallback(bytes calldata rawData) internal onlyPoolManager() override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        if (data.params.liquidityDelta < 0) {
            delta = _removeLiquidity(data.key, data.params);
            _takeDeltas(data.sender, data.key, delta);
        } else {
            (delta,) = manager.modifyLiquidity(data.key, data.params, bytes(""));
            _settleDeltas(data.sender, data.key, delta);
        }
        return abi.encode(delta);
    }

    function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        key.currency0.settle(manager, sender, uint256(int256(-delta.amount0())), false);
        key.currency1.settle(manager, sender, uint256(int256(-delta.amount1())), false);
    }

    function _takeDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        manager.take(key.currency0, sender, uint256(uint128(delta.amount0())));
        manager.take(key.currency1, sender, uint256(uint128(delta.amount1())));
    }

    function getCurrencies(
        IPoolManager.SwapParams calldata params,
        PoolKey calldata key,
        bool exactInput
    ) internal pure returns (Currency specified, Currency unspecified) {
        return (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
    }

    function getSpecifiedAmount(
        IPoolManager.SwapParams calldata params,
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
            if (amountOut + mintedTokens[id] > tokenToMintSupply[id]) revert PURCHASE_AMOUNT_TOO_BIG();
            if (zeroForOne) {
                int24 currTick = MINIMUM_TICK + int24((MAXIMUM_TICK - MINIMUM_TICK) * int256(mintedTokens[id]) / int256(tokenToMintSupply[id]));
                uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currTick);

                // maximum value of sqrtPriceX96 is sqrt(1.0001**-276324) * 2**96 < 2**77
                // maximum value of sqrtPriceX96**2 is 2**154
                // minimum value of sqrtPriceX96**2/tokensUsedToPurchase is (1.0001**-345405 * 2**192) / (1e9 * 1e6) > 1
                uint256 inverseTokenPurchased = 2**192 / uint256(specifiedAmount);
                amountIn = (inverseTokenPurchased * uint256(specifiedAmount)) / (uint256(sqrtPriceX96) ** 2);
            } else {
                int24 currTick = INVERT_MAXIMUM_TICK - int24((INVERT_MAXIMUM_TICK - INVERT_MINIMUM_TICK) * int256(mintedTokens[id]) / int256(tokenToMintSupply[id]));
                uint256 sqrtPriceX96 = uint256(TickMath.getSqrtPriceAtTick(currTick));

                // maximum value of sqrtPriceX96**2 is 1.0001 ** 345405 * 2**192 < 2**242
                // minimum value of sqrtPriceX96**2 is 1.0001 ** 276324 * 2**192 > 2**231
                // log2(1e25) = 2**83
                // 83 + 242 - 256 = 69
                // --> need to divide the initial product by 2**100
                uint256 priceX92 = (uint256(sqrtPriceX96) ** 2) / 2**100;
                amountIn = (2**92 * uint256(specifiedAmount)) / priceX92;
            }
            amountOut = uint256(specifiedAmount);

            mintedTokens[id] += amountOut;
        } else {
            if (poolToLPStartTime[id] == 0) revert INITIAL_LIQUIDITY_NOT_PROVIDED();
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
                uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currTick);

                // maximum value of sqrtPriceX96 is sqrt(1.0001**-276324) * 2**96 < 2**77
                // maximum value of sqrtPriceX96**2 is 2**154
                // minimum value of sqrtPriceX96**2/tokensUsedToPurchase is (1.0001**-345405 * 2**192) / (1e9 * 1e6) > 1
                uint256 inverseTokenPurchased =  (uint256(sqrtPriceX96) ** 2) / uint256(amountSpecified);
                amountOut = 2**192 / inverseTokenPurchased;
                if (mintedTokens[id] + amountOut > tokenToMintSupply[id]) {
                    amountOut = tokenToMintSupply[id] - mintedTokens[id];
                    amountIn = (uint256(sqrtPriceX96) ** 2) /  (2**192 / amountOut);
                    mintedTokens[id] = tokenToMintSupply[id];
                } else {
                    amountIn = uint256(amountSpecified);
                    mintedTokens[id] += amountOut;
                }
            } else {
                int24 currTick = INVERT_MAXIMUM_TICK - int24((INVERT_MAXIMUM_TICK - INVERT_MINIMUM_TICK) * int256(mintedTokens[id]) / int256(tokenToMintSupply[id]));
                uint256 sqrtPriceX96 = uint256(TickMath.getSqrtPriceAtTick(currTick));
                // maximum value of sqrtPriceX96**2 is 1.0001 ** 345405 * 2**192 < 2**242
                // minimum value of sqrtPriceX96**2 is 1.0001 ** 276324 * 2**192 > 2**231
                // log2(1e25) = 2**83
                // 83 + 242 - 256 = 69
                // --> need to divide the initial product by 2**100
                uint256 priceX92 = (uint256(sqrtPriceX96) ** 2) / 2**100;
                amountOut = priceX92 * amountSpecified / 2**92;
                if (mintedTokens[id] + amountOut > tokenToMintSupply[id]) {
                    amountOut = tokenToMintSupply[id] - mintedTokens[id];
                    amountIn = (2**92 * amountOut) / priceX92;
                    mintedTokens[id] = tokenToMintSupply[id];
                } else {
                    amountIn = uint256(amountSpecified);
                    mintedTokens[id] += amountOut;
                }
            }

            // amountIn = uint256(amountSpecified);

            // // Ideally, we want to mint the exact amount of tokens, then refund the remaining amount not used to the user
            // mintedTokens[id] += amountOut;
            // // TODO: Just quick fix here, change later
            // if (mintedTokens[id] + amountOut > tokenToMintSupply[id]) {
            //     amountOut -= mintedTokens[id] - tokenToMintSupply[id];
            //     mintedTokens[id] = tokenToMintSupply[id];
            // }
        } else {
            if (poolToLPStartTime[id] == 0) revert INITIAL_LIQUIDITY_NOT_PROVIDED();
            amountIn = 0;
            amountOut = 0;
        }
    }

    function addLiquidity(AddLiquidityParams calldata params)
    external
    returns (uint128 liquidity)
    {
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert POOL_NOT_INITIALIZED();

        // PoolInfo storage pool = poolInfo[poolId];

        uint128 poolLiquidity = manager.getLiquidity(poolId);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(key.tickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(key.tickSpacing)),
            params.amount0Desired,
            params.amount1Desired
        );

        // if (poolLiquidity == 0) {
        //     revert LiquidityDoesntMeetMinimum();
        // }
        BalanceDelta addedDelta = modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: liquidity.toInt256(),
                salt: 0
            })
        );

        // if (poolLiquidity == 0) {
        //     // permanently lock the first MINIMUM_LIQUIDITY tokens
        //     liquidity -= MINIMUM_LIQUIDITY;
        //     UniswapV4ERC20(pool.liquidityToken).mint(address(0), MINIMUM_LIQUIDITY);
        // }

        UniswapV4ERC20(poolLpToken[poolId]).mint(params.to, liquidity);

        if (uint128(-addedDelta.amount0()) < params.amount0Min || uint128(-addedDelta.amount1()) < params.amount1Min) {
            revert TOO_MUCH_SLIPPAGE();
        }
    }

    function removeLiquidity(RemoveLiquidityParams calldata params)
    public
    virtual
    returns (BalanceDelta delta)
    {
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert POOL_NOT_INITIALIZED();

        UniswapV4ERC20 erc20 = UniswapV4ERC20(poolLpToken[poolId]);

        delta = modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: -(params.liquidity.toInt256()),
                salt: 0
            })
        );

        erc20.burn(msg.sender, params.liquidity);
    }


    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
    internal
    returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));
    }

    function _removeLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
    internal
    returns (BalanceDelta delta)
    {
        PoolId poolId = key.toId();
        // PoolInfo storage pool = poolInfo[poolId];

        // if (pool.hasAccruedFees) {
        //     _rebalance(key);
        // }

        uint256 liquidityToRemove = FullMath.mulDiv(
            uint256(-params.liquidityDelta),
            manager.getLiquidity(poolId),
            UniswapV4ERC20(poolLpToken[poolId]).totalSupply()
        );

        params.liquidityDelta = -(liquidityToRemove.toInt256());
        (delta,) = manager.modifyLiquidity(key, params, bytes(""));
        // pool.hasAccruedFees = false;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        if (sender != address(this)) revert SENDER_MUST_BE_HOOK();

        return ExponentialLaunchpad.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        if (sender != address(this)) revert SENDER_MUST_BE_HOOK();

        return ExponentialLaunchpad.beforeRemoveLiquidity.selector;
    }
}