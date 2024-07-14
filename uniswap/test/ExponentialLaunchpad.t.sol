// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {HookMiner} from "./utils/HookMiner.sol";
import {ExponentialLaunchpad} from "../src/ExponentialLaunchpad.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

// Testing framework
// - Mint entire ERC20 supply to Pool
// - Enable exponential bonding curve
// -


contract ExponentialLaunchpadTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ExponentialLaunchpad hook;
    address public user = address(0x1);

    uint tokenSupplyToMint = 5e22;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG);

        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) =
                            HookMiner.find(address(this), flags, type(ExponentialLaunchpad).creationCode, abi.encode(address(manager), Currency.unwrap(currency0)));
        hook = new ExponentialLaunchpad{salt: salt}(IPoolManager(address(manager)), Currency.unwrap(currency0));
        require(address(hook) == hookAddress, "Launchpad: hook address mismatch");

        // Create the pool
        key = PoolKey(currency0, currency1, 0, 60, IHooks(address(hook)));
        // manager.initialize(key, SQRT_PRICE_1_1, abi.encodePacked(uint256(tokenSupplyToMint)));

        _setApprovalsFor(user, Currency.unwrap(currency0));
        _setApprovalsFor(user, Currency.unwrap(currency1));

        // initialize
        IERC20(Currency.unwrap(currency1)).approve(address(hook), tokenSupplyToMint);
        manager.unlock(abi.encode(key, SQRT_PRICE_1_1, abi.encodePacked(uint256(tokenSupplyToMint))));
    }

    function unlockCallback(bytes calldata callbackData) external returns (bytes memory) {
        require(msg.sender == address(manager), "Dutch Auction Launch Pad: unlockCallback sender is not the manager");
        (PoolKey memory key, uint160 sqrtPriceX96, bytes memory hookData) = abi.decode(callbackData, (PoolKey, uint160, bytes));
        manager.initialize(key, sqrtPriceX96, hookData);
    }    

    function _setApprovalsFor(address _user, address token) internal {
        address[8] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor())
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            vm.prank(_user);
            MockERC20(token).approve(toApprove[i], type(uint256).max);
        }
    }

    function test_LaunchpadHooksInitialize() public {
        PoolId poolId = key.toId();
        // Check that beforeInitialize was called
        assertEq(hook.tokenToMintSupply(poolId), tokenSupplyToMint);
    }

    function test_bondingCurveSwap_exactInput() public {
        // Send currency1 to the hook (meme coin)
        currency0.transfer(address(user), 20e18);
        currency1.transfer(address(hook), 1e18 * 1e10);
        currency0.transfer(address(hook), 1e18 * 1e10);

        (uint256 initialUserBalance0, uint256 initialUserBalance1, uint256 initialHookBalance0, uint256 initialHookBalance1) = getUserAndHookBalance();

        int256 amountSpecified = -1e8;
        BalanceDelta swapDelta = swapToCurrency1(amountSpecified);

        (uint256 finalUserBalance0, uint256 finalUserBalance1, uint256 finalHookBalance0, uint256 finalHookBalance1) = getUserAndHookBalance();

        assertEq(int256(swapDelta.amount0()), amountSpecified);
        uint256 token1Output = finalUserBalance1 - initialUserBalance1;
        assertEq(int256(swapDelta.amount1()), int256(token1Output));

        // assertEq(token1Output, 99999669522114109916642);
        assertEq(token1Output, 50000000000000000000000);
    }

    function test_bondingCurveSwap_exactOutput() public {
        // Send currency1 to the hook (meme coin)
        currency0.transfer(address(user), 20e18);
        currency1.transfer(address(hook), 1e18 * 1e10);

        (uint256 initialUserBalance0, uint256 initialUserBalance1, uint256 initialHookBalance0, uint256 initialHookBalance1) = getUserAndHookBalance();

        int256 amountSpecified = 1e8;
        BalanceDelta swapDelta = swapToCurrency1(amountSpecified);

        (uint256 finalUserBalance0, uint256 finalUserBalance1, uint256 finalHookBalance0, uint256 finalHookBalance1) = getUserAndHookBalance();

        assertEq(finalUserBalance0 + finalHookBalance0, initialUserBalance0 + initialHookBalance0);
        assertEq(finalUserBalance1 + finalHookBalance1, initialUserBalance1 + initialHookBalance1);

        int256 token0Output = int256(finalUserBalance0) - int256(initialUserBalance0);
        assertEq(int256(swapDelta.amount0()), token0Output);
        assertEq(int256(swapDelta.amount1()), amountSpecified);

        assertEq(token0Output, -999996695221141);
    }


    // after the 1st swap, price of the token 1 will increase because more token 1 has been minted, 
    // hence, with the same token 0 amount to be swapped in both 1st and 2nd swap, 2nd swap will result in lesser token 1 than 1st swap
    function test_multipleSwap_priceMovement() public {
        // Send currency1 to the hook (meme coin)
        currency0.transfer(address(user), 20e18);
        currency1.transfer(address(hook), 1e18 * 1e10);

        (uint256 firstUserBalance0, uint256 firstUserBalance1, uint256 firstHookBalance0, uint256 firstHookBalance1) = getUserAndHookBalance();

        swapToCurrency1(-1e2);
         
        (uint256 secondUserBalance0, uint256 secondUserBalance1, uint256 secondHookBalance0, uint256 secondHookBalance1) = getUserAndHookBalance();

        int256 token1UserGetsFor1stSwap = int256(secondUserBalance1 - firstUserBalance1);

        swapToCurrency1(-1e2);

        (uint256 thirdUserBalance0, uint256 thirdUserBalance1, uint256 thirdHookBalance0, uint256 thirdHookBalance1) = getUserAndHookBalance();

        int256 token1UserGetsFor2ndSwap = int256(thirdUserBalance1 - secondUserBalance1);
    
        // with same amount of token 0 to be swapped in both 1st and 2nd swap, 2nd swap will result in lesser token 1 token as token 1 price increases when more token has been minted 
        assertLe(token1UserGetsFor2ndSwap, token1UserGetsFor1stSwap);

        // after 2 swap of 100 token 1, hook will have 200 token 1 as balance
        assertEq(thirdHookBalance0, 200);
    }

    function test_add_and_remove_liquidity() public {        
        currency0.transfer(address(user), 20e18);
        currency1.transfer(address(user), 20e18);
        uint256 balanceBeforeAddLiquidity0 = currency0.balanceOf(address(manager));
        uint256 balanceBeforeAddLiquidity1 = currency1.balanceOf(address(manager));
        vm.startPrank(user);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);
        uint128 liquidity = hook.addLiquidity(ExponentialLaunchpad.AddLiquidityParams({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: key.fee, 
            amount0Desired: 1e18,
            amount1Desired: 1e18,
            amount0Min: 0,
            amount1Min: 0, 
            to: address(user),
            deadline: block.timestamp + 1000
        }));
        vm.stopPrank();
        assertEq(currency0.balanceOf(address(manager)) - balanceBeforeAddLiquidity0, 1e18);
        assertEq(currency1.balanceOf(address(manager)) - balanceBeforeAddLiquidity1, 1e18);


        uint256 balanceUserBeforeRemoveLiquidity0 = currency0.balanceOf(address(user));
        uint256 balanceUserBeforeRemoveLiquidity1 = currency1.balanceOf(address(user));
        vm.startPrank(user);
        hook.removeLiquidity(ExponentialLaunchpad.RemoveLiquidityParams({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: key.fee, 
            liquidity: liquidity, 
            deadline: block.timestamp + 1000
        }));
        vm.stopPrank();
        assertEq(currency0.balanceOf(address(user)) - balanceUserBeforeRemoveLiquidity0, 1e18 - 1);
        assertEq(currency1.balanceOf(address(user)) - balanceUserBeforeRemoveLiquidity1, 1e18 - 1);
    }

    function swapToCurrency1(int256 amountSpecified) public returns (BalanceDelta swapDelta)  {
        bool zeroForOne = true;

        vm.startPrank(user);
        swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        vm.stopPrank();
    }

    function getUserAndHookBalance() public returns (uint256 userBalance0, uint256 userBalance1, uint256 hookBalance0, uint256 hookBalance1) {
        uint256 userBalance0 = currency0.balanceOf(address(user));
        uint256 userBalance1 = currency1.balanceOf(address(user));

        uint256 hookBalance0 = currency0.balanceOf(address(hook));
        uint256 hookBalance1 = currency1.balanceOf(address(hook));

        return (userBalance0, userBalance1, hookBalance0, hookBalance1);
    }

}