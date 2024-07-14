pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
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
import {CLPoolParametersHelper} from "@pancakeswap/v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {SD59x18, sd} from "@prb/math/src/SD59x18.sol";
import {ICLSwapRouterBase} from "@pancakeswap/v4-periphery/src/pool-cl/interfaces/ICLSwapRouterBase.sol";
import { Constants } from "@pancakeswap/v4-core/src/pool-bin/libraries/Constants.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {CLTestUtils} from "./utils/CLTestUtils.sol";

import {DutchAuctionLaunchPad} from "../src/pool-cl/DutchAuctionLaunchPad.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}
contract DutchAuctionLaunchPadTest is Test, CLTestUtils {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    DutchAuctionLaunchPad hook;
    Currency currency0;
    Currency currency1;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        // Deployers.deployFreshManagerAndRouters();
        // Deployers.deployMintAndApprove2Currencies();
        // uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
    
        // (address hookAddress, bytes32 salt) = 
        //     HookMiner.find(address(this), flags, type(DutchAuctionLaunchPad).creationCode, abi.encode(address(manager)));

        (currency0, currency1) = deployContractsWithTokens();

        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), 10 ether);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), 10 ether);

        hook = new DutchAuctionLaunchPad (ICLPoolManager(address(poolManager)));

        MockERC20(Currency.unwrap(currency0)).mint(address(hook), 10000 ether);
        MockERC20(Currency.unwrap(currency0)).mint(address(poolManager), 10000 ether);
        MockERC20(Currency.unwrap(currency0)).mint(address(vault), 10000 ether);

        MockERC20(Currency.unwrap(currency1)).mint(address(hook), 10000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(poolManager), 10000 ether);
        MockERC20(Currency.unwrap(currency1)).mint(address(vault), 10000 ether);

        // require(hookAddress == address(hook), "Dutch Auction Launch Pad: hook address mismatch");
        // Create the pool
        // poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: hook,
            poolManager: poolManager,
            fee: uint24(3000), // 0.3% fee
            // tickSpacing: 10
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setTickSpacing(60)
        });

        poolId = poolKey.toId();
        bytes memory hookData;
        {
            int256 _salePeriod = 1000; // 1000 s
            int256 _initialTokenSupply = 3_000_000; // 3 mil tokens
            int256 _initialPrice = 10_000_000; // 10 USDC
            int256 _decayConstant = 1; 
            int256 _emissionRate = 1;
            address _paymentToken = Currency.unwrap(currency0);
            hookData = abi.encode(_salePeriod, _initialTokenSupply, _initialPrice, _decayConstant, _emissionRate, _paymentToken, address(this));
        }

        // vault.lock(abi.encode(poolKey, 79228162514264337593543950336, hookData));
        poolManager.initialize(poolKey, 79228162514264337593543950336, hookData);
    }

    function unlockCallback(bytes calldata callbackData) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Dutch Auction Launch Pad: unlockCallback sender is not the manager");
        (PoolKey memory key, uint160 sqrtPriceX96, bytes memory hookData) = abi.decode(callbackData, (PoolKey, uint160, bytes));
        poolManager.initialize(key, sqrtPriceX96, hookData);
    }

    function testSwapWithoutPrank() public {
        // mint the initial supply
        uint256 balanceCurrency0BeforeSwapping = currency0.balanceOfSelf();
        uint256 balanceCurrency1BeforeSwapping = currency1.balanceOfSelf();
        skip(10);
        // swap(poolKey, true, 5, abi.encode(address(this)));
        swapRouter.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: true,
                recipient: address(this),
                amountIn: 5,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp
        );

        uint256 balanceCurrency0AfterSwapping = currency0.balanceOfSelf();
        uint256 balanceCurrency1AfterSwapping = currency1.balanceOfSelf();      
        assertEq(balanceCurrency0BeforeSwapping - balanceCurrency0AfterSwapping, 66925, "Incorrect amount of currency1 swapped");
        assertEq(balanceCurrency1AfterSwapping - balanceCurrency1BeforeSwapping, 5, "Incorrect amount of currency0 swapped");
    }

    function testSwapWithPrank() public {
        // mint the initial supply
        currency0.transfer(address(1), 1_000_000);
        skip(10);        
        uint256 balanceCurrency0BeforeSwapping = currency0.balanceOf(address(1));
        uint256 balanceCurrency1BeforeSwapping = currency1.balanceOf(address(1));
        vm.startPrank(address(1));
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), 1_000_000);
        // swap(poolKey, true, 5, abi.encode(address(this)));
        swapRouter.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: true,
                recipient: address(this),
                amountIn: 5,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp
        );

        vm.stopPrank();
        uint256 balanceCurrency0AfterSwapping = currency0.balanceOf(address(1));
        uint256 balanceCurrency1AfterSwapping = currency1.balanceOf(address(1));      
        assertEq(balanceCurrency0BeforeSwapping - balanceCurrency0AfterSwapping, 66925, "Incorrect amount of currency1 swapped");
        assertEq(balanceCurrency1AfterSwapping - balanceCurrency1BeforeSwapping, 5, "Incorrect amount of currency0 swapped");
    }
}