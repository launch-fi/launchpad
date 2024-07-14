// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {BinPoolManager} from "pancake-v4-core/src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";

import {TokenFixture} from "../helpers/TokenFixture.sol";
import {LiquidityParamsHelper} from "./helpers/LiquidityParamsHelper.sol";
import {IBinSwapRouterBase} from "../../src/pool-bin/interfaces/IBinSwapRouterBase.sol";
import {BinSwapRouter} from "../../src/pool-bin/BinSwapRouter.sol";
import {IBinFungiblePositionManager} from "../../src/pool-bin/interfaces/IBinFungiblePositionManager.sol";
import {BinFungiblePositionManager} from "../../src/pool-bin/BinFungiblePositionManager.sol";
import {ISwapRouterBase} from "../../src/interfaces/ISwapRouterBase.sol";

contract BinSwapRouterHandler is Test, LiquidityParamsHelper {
    using BinPoolParametersHelper for bytes32;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    PoolKey public poolKey;
    PoolKey public nativePoolKey;
    Vault public vault;
    BinSwapRouter public router;
    BinFungiblePositionManager public binFungiblePositionManager;
    BinPoolManager public poolManager;
    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    address public alice = makeAddr("alice");

    MockERC20 public token0;
    MockERC20 public token1;
    Currency public currency0;
    Currency public currency1;
    uint256 public token0Minted;
    uint256 public token1Minted;
    uint256 public nativeTokenMinted;

    constructor() {
        WETH weth = new WETH();
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)), 500000);
        vault.registerApp(address(poolManager));

        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        (token0, token1) = address(token0) > address(token1) ? (token1, token0) : (token0, token1);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // router and position manager
        binFungiblePositionManager =
            new BinFungiblePositionManager(IVault(address(vault)), IBinPoolManager(address(poolManager)), address(weth));
        router = new BinSwapRouter(vault, poolManager, address(weth));

        bytes32 poolParam;
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        poolManager.initialize(poolKey, activeId, new bytes(0));

        nativePoolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            parameters: poolParam.setBinStep(10) // binStep
        });
        poolManager.initialize(nativePoolKey, activeId, new bytes(0));

        vm.startPrank(alice);
        token0.approve(address(binFungiblePositionManager), type(uint256).max);
        token1.approve(address(binFungiblePositionManager), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function exactSwapInputSingle(uint128 amtIn, bool isNativePool) public {
        // Ensure at least some liquidity minted and amoutOut when swap > 0
        amtIn = uint128(bound(amtIn, 10, 100 ether));

        // step 1: Mint token to alice for swap and add liquidity
        _mint(amtIn, isNativePool);

        // Step 2: Mint token for alice to swap
        isNativePool ? vm.deal(alice, amtIn) : token0.mint(alice, amtIn);
        isNativePool ? nativeTokenMinted += amtIn : token0Minted += amtIn;

        // Step 3: swap
        PoolKey memory pk = isNativePool ? nativePoolKey : poolKey;
        // if native pool, have to ensure call method with value
        uint256 value = isNativePool ? amtIn : 0;
        vm.prank(alice);
        router.exactInputSingle{value: value}(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: pk,
                swapForY: true, // swap token0 for ETH
                recipient: alice,
                amountIn: amtIn,
                amountOutMinimum: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );
    }

    function exactSwapInput(uint128 amtIn, bool isNativePool) public {
        // Ensure at least some liquidity minted and amoutOut when swap > 0
        amtIn = uint128(bound(amtIn, 10, 100 ether));

        // step 1: Mint token to alice for swap and add liquidity
        _mint(amtIn, isNativePool);

        // Step 2: Mint token for alice to swap
        isNativePool ? vm.deal(alice, amtIn) : token0.mint(alice, amtIn);
        isNativePool ? nativeTokenMinted += amtIn : token0Minted += amtIn;

        // Step 3: swap
        PoolKey memory pk = isNativePool ? nativePoolKey : poolKey;
        vm.prank(alice);
        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](1);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: pk.fee,
            hooks: pk.hooks,
            hookData: new bytes(0),
            poolManager: pk.poolManager,
            parameters: pk.parameters
        });

        // if native pool, have to ensure call method with value
        uint256 value = isNativePool ? amtIn : 0;
        router.exactInput{value: value}(
            IBinSwapRouterBase.V4BinExactInputParams({
                currencyIn: isNativePool ? CurrencyLibrary.NATIVE : currency0,
                path: path,
                recipient: alice,
                amountIn: amtIn,
                amountOutMinimum: 0
            }),
            block.timestamp + 60
        );
    }

    function exactSwapOutputSingle(uint128 amtIn, bool isNativePool) public {
        amtIn = uint128(bound(amtIn, 10, 100 ether));

        // step 1: Mint token to alice for swap and add liquidity
        _mint(amtIn, isNativePool);

        // Step 2: Mint token for alice to swap
        isNativePool ? vm.deal(alice, amtIn) : token0.mint(alice, amtIn);
        isNativePool ? nativeTokenMinted += amtIn : token0Minted += amtIn;

        // Step 3: swap
        PoolKey memory pk = isNativePool ? nativePoolKey : poolKey;
        // if native pool, have to ensure call method with value
        uint256 value = isNativePool ? amtIn : 0;
        vm.prank(alice);
        router.exactOutputSingle{value: value}(
            IBinSwapRouterBase.V4BinExactOutputSingleParams({
                poolKey: pk,
                swapForY: true,
                recipient: alice,
                amountOut: amtIn / 2,
                amountInMaximum: amtIn,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );
    }

    function exactSwapOutput(uint128 amtIn, bool isNativePool) public {
        amtIn = uint128(bound(amtIn, 10, 100 ether));

        // step 1: Mint token to alice for swap and add liquidity
        _mint(amtIn, isNativePool);

        // Step 2: Mint token for alice to swap
        isNativePool ? vm.deal(alice, amtIn) : token0.mint(alice, amtIn);
        isNativePool ? nativeTokenMinted += amtIn : token0Minted += amtIn;

        // Step 3: swap
        PoolKey memory pk = isNativePool ? nativePoolKey : poolKey;
        vm.prank(alice);
        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](1);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: isNativePool ? CurrencyLibrary.NATIVE : currency0,
            fee: pk.fee,
            hooks: pk.hooks,
            hookData: new bytes(0),
            poolManager: pk.poolManager,
            parameters: pk.parameters
        });

        // if native pool, have to ensure call method with value
        uint256 value = isNativePool ? amtIn : 0;
        router.exactOutput{value: value}(
            IBinSwapRouterBase.V4BinExactOutputParams({
                currencyOut: Currency.wrap(address(token1)),
                path: path,
                recipient: alice,
                amountOut: amtIn / 2,
                amountInMaximum: amtIn
            }),
            block.timestamp + 60
        );
    }

    function _mint(uint128 amt, bool isNativePool) private {
        /// @dev given that amt is cap at 100 ether, we can safely mint 5x the amount to reduce slippage in trading
        amt = amt * 10;

        // step 1: Mint token to alice for add liquidity
        isNativePool ? vm.deal(alice, amt) : token0.mint(alice, amt);
        isNativePool ? nativeTokenMinted += amt : token0Minted += amt;
        token1Minted += amt;
        token1.mint(alice, amt);

        // Step 2: add liquidity around activeId
        PoolKey memory pk = isNativePool ? nativePoolKey : poolKey;
        vm.startPrank(alice);
        (activeId,,) = poolManager.getSlot0(pk.toId());
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory addParams;
        addParams = _getAddParams(pk, binIds, amt, amt, activeId, alice);
        if (isNativePool) {
            binFungiblePositionManager.addLiquidity{value: amt}(addParams);
        } else {
            binFungiblePositionManager.addLiquidity(addParams);
        }
        vm.stopPrank();
    }
}

contract BinSwapRouterInvariant is Test {
    BinSwapRouterHandler _handler;

    function setUp() public {
        // deploy necessary contract
        _handler = new BinSwapRouterHandler();

        // only call BinSwapRouterHandler
        targetContract(address(_handler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = BinSwapRouterHandler.exactSwapInputSingle.selector;
        selectors[1] = BinSwapRouterHandler.exactSwapOutputSingle.selector;
        selectors[2] = BinSwapRouterHandler.exactSwapInput.selector;
        selectors[3] = BinSwapRouterHandler.exactSwapOutput.selector;
        targetSelector(FuzzSelector({addr: address(_handler), selectors: selectors}));
    }

    /// @dev token minted should be either in vault or with alice
    function invariant_AllTokensInVaultOrUser() public view {
        IVault vault = IVault(_handler.vault());

        // verify token0
        uint256 token0BalInVault = _handler.token0().balanceOf(address(vault));
        uint256 token0WithAlice = _handler.token0().balanceOf(_handler.alice());
        assertEq(token0BalInVault + token0WithAlice, _handler.token0Minted());

        // verify token1
        uint256 token1BalInVault = _handler.token1().balanceOf(address(vault));
        uint256 token1WithAlice = _handler.token1().balanceOf(_handler.alice());
        assertEq(token1BalInVault + token1WithAlice, _handler.token1Minted());

        // eth case will also need to check router balance
        uint256 nativeTokenInVault = address(vault).balance;
        uint256 nativeTokenWithAlice = _handler.alice().balance;
        uint256 routerBalance = address(_handler.router()).balance;
        assertEq(nativeTokenInVault + nativeTokenWithAlice + routerBalance, _handler.nativeTokenMinted());
    }
}
