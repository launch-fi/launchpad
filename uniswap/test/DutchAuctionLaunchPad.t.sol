pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol"; 
import {HookMiner} from "./utils/HookMiner.sol";
import {DutchAuctionLaunchPad} from "src/DutchAuctionLaunchpad.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SD59x18} from "@prb/math/src/SD59x18.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}
contract DutchAuctionLaunchPadTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    DutchAuctionLaunchPad hook;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
    
        (address hookAddress, bytes32 salt) = 
            HookMiner.find(address(this), flags, type(DutchAuctionLaunchPad).creationCode, abi.encode(address(manager)));
        hook = new DutchAuctionLaunchPad{salt: salt}(IPoolManager(address(manager)));
        require(hookAddress == address(hook), "Dutch Auction Launch Pad: hook address mismatch");
        // Create the pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        bytes memory hookData;
        {
            int256 _salePeriod = 1000; // 1000 s
            int256 _initialTokenSupply = 3_000_000; // 3 mil tokens
            int256 _initialPrice = 10_000_000; // 10 USDC
            int256 _decayConstant = 1; 
            int256 _emissionRate = 1;
            address _paymentToken = Currency.unwrap(Deployers.currency0);
            hookData = abi.encode(_salePeriod, _initialTokenSupply, _initialPrice, _decayConstant, _emissionRate, _paymentToken, address(this));
        }
        IERC20(Currency.unwrap(Deployers.currency1)).approve(address(hook), 3_000_000);
        manager.unlock(abi.encode(poolKey, SQRT_PRICE_1_1, hookData));
        // manager.initialize(poolKey, SQRT_PRICE_1_1, hookData);
    }

    function unlockCallback(bytes calldata callbackData) external returns (bytes memory) {
        require(msg.sender == address(manager), "Dutch Auction Launch Pad: unlockCallback sender is not the manager");
        (PoolKey memory key, uint160 sqrtPriceX96, bytes memory hookData) = abi.decode(callbackData, (PoolKey, uint160, bytes));
        manager.initialize(key, sqrtPriceX96, hookData);
    }

    function testSwapWithoutPrank() public {
        // mint the initial supply
        uint256 balanceCurrency0BeforeSwapping = currency0.balanceOfSelf();
        uint256 balanceCurrency1BeforeSwapping = currency1.balanceOfSelf();
        skip(10);
        swap(poolKey, true, 5, abi.encode(address(this)));
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
        IERC20(Currency.unwrap(Deployers.currency0)).approve(address(swapRouter), 1_000_000);
        swap(poolKey, true, 5, abi.encode(address(this)));
        vm.stopPrank();
        uint256 balanceCurrency0AfterSwapping = currency0.balanceOf(address(1));
        uint256 balanceCurrency1AfterSwapping = currency1.balanceOf(address(1));      
        assertEq(balanceCurrency0BeforeSwapping - balanceCurrency0AfterSwapping, 66925, "Incorrect amount of currency1 swapped");
        assertEq(balanceCurrency1AfterSwapping - balanceCurrency1BeforeSwapping, 5, "Incorrect amount of currency0 swapped");
    }
}