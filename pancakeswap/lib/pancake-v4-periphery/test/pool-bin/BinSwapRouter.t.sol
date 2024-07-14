// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {BinHelper} from "pancake-v4-core/src/pool-bin/libraries/BinHelper.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolManager} from "pancake-v4-core/src/pool-bin/BinPoolManager.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {BinFungiblePositionManager} from "../../src/pool-bin/BinFungiblePositionManager.sol";
import {IBinFungiblePositionManager} from "../../src/pool-bin/interfaces/IBinFungiblePositionManager.sol";
import {LiquidityParamsHelper} from "./helpers/LiquidityParamsHelper.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {BeforeMintSwapHook} from "./helpers/BeforeMintSwapHook.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PackedUint128Math} from "pancake-v4-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {BinSwapRouter} from "../../src/pool-bin/BinSwapRouter.sol";
import {BinSwapRouterBase} from "../../src/pool-bin/BinSwapRouterBase.sol";
import {IBinSwapRouterBase} from "../../src/pool-bin/interfaces/IBinSwapRouterBase.sol";
import {ISwapRouterBase} from "../../src/interfaces/ISwapRouterBase.sol";
import {SwapRouterBase} from "../../src/SwapRouterBase.sol";
import {PeripheryPayments} from "../../src/base/PeripheryPayments.sol";
import {PeripheryValidation} from "../../src/base/PeripheryValidation.sol";

contract BinSwapRouterTest is Test, GasSnapshot, LiquidityParamsHelper {
    using BinPoolParametersHelper for bytes32;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    bytes constant ZERO_BYTES = new bytes(0);

    PoolKey key;
    PoolKey key2;
    PoolKey key3;
    Vault vault;
    BinPoolManager poolManager;
    BinFungiblePositionManager binFungiblePositionManager;
    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;
    bytes32 poolParam;
    BinSwapRouter router;
    WETH weth;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    function setUp() public {
        weth = new WETH();
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)), 500000);
        vault.registerApp(address(poolManager));
        router = new BinSwapRouter(vault, poolManager, address(weth));

        binFungiblePositionManager =
            new BinFungiblePositionManager(IVault(address(vault)), IBinPoolManager(address(poolManager)), address(weth));

        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        token2 = new MockERC20("TestC", "C", 18);

        // sort token
        (token0, token1) = token0 > token1 ? (token1, token0) : (token0, token1);
        if (token2 < token0) {
            (token0, token1, token2) = (token2, token0, token1);
        } else if (token2 < token1) {
            (token1, token2) = (token2, token1);
        }

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        key2 = PoolKey({
            currency0: Currency.wrap(address(token1)),
            currency1: Currency.wrap(address(token2)),
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        key3 = PoolKey({
            currency0: Currency.wrap(address(address(0))),
            currency1: Currency.wrap(address(token0)),
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });

        poolManager.initialize(key, activeId, ZERO_BYTES);
        poolManager.initialize(key2, activeId, ZERO_BYTES);
        poolManager.initialize(key3, activeId, ZERO_BYTES);

        vm.startPrank(alice);
        token0.approve(address(binFungiblePositionManager), 1000 ether);
        token1.approve(address(binFungiblePositionManager), 1000 ether);
        token2.approve(address(binFungiblePositionManager), 1000 ether);
        token0.approve(address(router), 1000 ether);
        token1.approve(address(router), 1000 ether);
        token2.approve(address(router), 1000 ether);

        // add liquidity, 10 ether across 3 bins for both pool
        token0.mint(alice, 10 ether);
        token1.mint(alice, 20 ether); // 20 as token1 is used in both pool
        token2.mint(alice, 10 ether);
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory addParams;
        addParams = _getAddParams(key, binIds, 10 ether, 10 ether, activeId, alice);
        binFungiblePositionManager.addLiquidity(addParams);
        addParams = _getAddParams(key2, binIds, 10 ether, 10 ether, activeId, alice);
        binFungiblePositionManager.addLiquidity(addParams);

        // add liquidity for ETH-token0 native pool (10 eth each)
        token0.mint(alice, 10 ether);
        vm.deal(alice, 10 ether);
        addParams = _getAddParams(key3, binIds, 10 ether, 10 ether, activeId, alice);
        binFungiblePositionManager.addLiquidity{value: 10 ether}(addParams);
    }

    function testLockAcquired_VaultOnly() public {
        vm.expectRevert(SwapRouterBase.NotVault.selector);
        router.lockAcquired(new bytes(0));
    }

    function testSweepToken() public {
        token0.mint(address(router), 1 ether);
        assertEq(token0.balanceOf(address(router)), 1 ether);

        vm.expectRevert(PeripheryPayments.InsufficientToken.selector);
        router.sweepToken(Currency.wrap(address(token0)), 2 ether, alice);

        // take
        router.sweepToken(Currency.wrap(address(token0)), 0.5 ether, alice);
        assertEq(token0.balanceOf(address(router)), 0 ether);
        assertEq(token0.balanceOf(address(alice)), 1 ether);
    }

    function testUnwrapWETH9() public {
        vm.startPrank(alice);

        vm.deal(alice, 1 ether);
        weth.deposit{value: 1 ether}();
        weth.transfer(address(router), 1 ether);
        assertEq(weth.balanceOf(address(router)), 1 ether);

        // unwrap with amtMin > amount in router
        vm.expectRevert(PeripheryPayments.InsufficientToken.selector);
        router.unwrapWETH9(2 ether, alice);

        // unwrap
        assertEq(alice.balance, 0 ether);
        router.unwrapWETH9(0.5 ether, alice);
        assertEq(weth.balanceOf(address(router)), 0 ether);
        assertEq(alice.balance, 1 ether);
    }

    function testExactInputSingle_EthPool_SwapEthForToken() public {
        vm.startPrank(alice);

        vm.deal(alice, 1 ether);
        assertEq(alice.balance, 1 ether);
        assertEq(token0.balanceOf(alice), 0 ether);

        snapStart("BinSwapRouterTest#testExactInputSingle_EthPool_SwapEthForToken");
        uint256 amountOut = router.exactInputSingle{value: 1 ether}(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key3,
                swapForY: true, // swap ETH for token0
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );
        snapEnd();

        assertEq(amountOut, 997000000000000000);
        assertEq(alice.balance, 0 ether);
        assertEq(token0.balanceOf(alice), amountOut);
    }

    function testExactInputSingle_EthPool_SwapEthForToken_RefundETH() public {
        vm.startPrank(alice);

        vm.deal(alice, 2 ether);
        assertEq(alice.balance, 2 ether);
        assertEq(token0.balanceOf(alice), 0 ether);

        // provide 2 eth but swap only required 1
        router.exactInputSingle{value: 2 ether}(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key3,
                swapForY: true, // swap ETH for token0
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );

        // verify contract still have 1 eth
        assertEq(alice.balance, 0 ether);
        assertEq(address(router).balance, 1 ether);

        // call router refund excess eth
        router.refundETH();
        assertEq(alice.balance, 1 ether);
        assertEq(address(router).balance, 0 ether);
    }

    function testExactInputSingle_EthPool_SwapTokenForEth() public {
        vm.startPrank(alice);

        token0.mint(alice, 1 ether);
        assertEq(alice.balance, 0 ether);
        assertEq(token0.balanceOf(alice), 1 ether);

        snapStart("BinSwapRouterTest#testExactInputSingle_EthPool_SwapTokenForEth");
        uint256 amountOut = router.exactInputSingle(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key3,
                swapForY: false, // swap token0 for ETH
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );
        snapEnd();

        assertEq(amountOut, 997000000000000000);
        assertEq(alice.balance, amountOut);
        assertEq(token0.balanceOf(alice), 0 ether);
    }

    function testExactInputSingle_EthPool_InsufficientETH() public {
        vm.deal(alice, 1 ether);

        vm.expectRevert(); // OutOfFund
        router.exactInputSingle{value: 0.5 ether}(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key3,
                swapForY: true,
                recipient: alice,
                amountIn: 1 ether, // swap ETH for token0
                amountOutMinimum: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );
    }

    /// @param swapForY if true = swap token0 for token1
    function testExactInputSingle_SwapForY(bool swapForY) public {
        vm.startPrank(alice);

        // before swap
        if (swapForY) {
            token0.mint(alice, 1 ether);
            assertEq(token0.balanceOf(alice), 1 ether);
            assertEq(token1.balanceOf(alice), 0 ether);
        } else {
            token1.mint(alice, 1 ether);
            assertEq(token0.balanceOf(alice), 0 ether);
            assertEq(token1.balanceOf(alice), 1 ether);
        }

        string memory gasSnapshotName = swapForY
            ? "BinSwapRouterTest#testExactInputSingle_SwapForY_1"
            : "BinSwapRouterTest#testExactInputSingle_SwapForY_2";

        snapStart(gasSnapshotName);
        uint256 amountOut = router.exactInputSingle(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key,
                swapForY: swapForY,
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );
        snapEnd();

        assertEq(amountOut, 997000000000000000);
        if (swapForY) {
            assertEq(token0.balanceOf(alice), 0 ether);
            assertEq(token1.balanceOf(alice), amountOut);
        } else {
            assertEq(token0.balanceOf(alice), amountOut);
            assertEq(token1.balanceOf(alice), 0 ether);
        }
    }

    function testExactInputSingle_AmountOutMin() public {
        vm.startPrank(alice);

        token0.mint(alice, 1 ether);

        vm.expectRevert(ISwapRouterBase.TooLittleReceived.selector);
        router.exactInputSingle(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key,
                swapForY: true,
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 1 ether, // activeId is 2**23, token price are same, so output is always lesser than 1 ether after fee/slippage
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );
    }

    function testExactInputSingle_Deadline() public {
        vm.startPrank(alice);

        token0.mint(alice, 1 ether);
        vm.warp(1000); // set block.timestamp

        vm.expectRevert(abi.encodeWithSelector(PeripheryValidation.TransactionTooOld.selector));
        router.exactInputSingle(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key,
                swapForY: true,
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: new bytes(0)
            }),
            block.timestamp - 100 // timestamp expired
        );
    }

    function testExactInputSingle_DifferentRecipient() public {
        vm.startPrank(alice);

        token0.mint(alice, 1 ether);
        vm.warp(1000); // set block.timestamp

        snapStart("BinSwapRouterTest#testExactInputSingle_DifferentRecipient");
        uint256 amountOut = router.exactInputSingle(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key,
                swapForY: true,
                recipient: bob, // bob
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );
        snapEnd();

        assertEq(token1.balanceOf(bob), amountOut);
        assertEq(token1.balanceOf(alice), 0);
    }

    function testExactInput_SingleHop() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](1);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        uint256 amountOut = router.exactInput(
            IBinSwapRouterBase.V4BinExactInputParams({
                currencyIn: Currency.wrap(address(token0)),
                path: path,
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 0
            }),
            block.timestamp + 60
        );
        assertEq(token1.balanceOf(alice), amountOut);
    }

    function testExactInput_MultiHopDifferentRecipient() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](2);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });
        path[1] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token2)),
            fee: key2.fee,
            hooks: key2.hooks,
            hookData: new bytes(0),
            poolManager: key2.poolManager,
            parameters: key2.parameters
        });

        snapStart("BinSwapRouterTest#testExactInput_MultiHopDifferentRecipient");
        uint256 amountOut = router.exactInput(
            IBinSwapRouterBase.V4BinExactInputParams({
                currencyIn: Currency.wrap(address(token0)),
                path: path,
                recipient: bob,
                amountIn: 1 ether,
                amountOutMinimum: 0
            }),
            block.timestamp + 60
        );
        snapEnd();

        // 1 ether * 0.997 * 0.997 (0.3% fee twice)
        assertEq(amountOut, 994009000000000000);
        assertEq(token2.balanceOf(alice), 0);
        assertEq(token2.balanceOf(bob), amountOut);
    }

    function testExactInput_Deadline() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);
        vm.warp(1000); // set block.timestamp

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](1);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        vm.expectRevert(abi.encodeWithSelector(PeripheryValidation.TransactionTooOld.selector));
        router.exactInput(
            IBinSwapRouterBase.V4BinExactInputParams({
                currencyIn: Currency.wrap(address(token0)),
                path: path,
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 0
            }),
            block.timestamp - 100 // timestamp expired
        );
    }

    function testExactInput_AmountOutMin() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](1);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        vm.expectRevert(ISwapRouterBase.TooLittleReceived.selector);
        router.exactInput(
            IBinSwapRouterBase.V4BinExactInputParams({
                currencyIn: Currency.wrap(address(token0)),
                path: path,
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 1 ether // min amount will only be 1 ether * 0.997
            }),
            block.timestamp + 60
        );
    }

    function testExactOutputSingle_SwapForY(bool swapForY) public {
        vm.startPrank(alice);

        // before swap
        if (swapForY) {
            token0.mint(alice, 1 ether);
            assertEq(token0.balanceOf(alice), 1 ether);
            assertEq(token1.balanceOf(alice), 0 ether);
        } else {
            token1.mint(alice, 1 ether);
            assertEq(token0.balanceOf(alice), 0 ether);
            assertEq(token1.balanceOf(alice), 1 ether);
        }

        string memory gasSnapshotName = swapForY
            ? "BinSwapRouterTest#testExactOutputSingle_SwapForY_1"
            : "BinSwapRouterTest#testExactOutputSingle_SwapForY_2";

        snapStart(gasSnapshotName);
        uint256 amountIn = router.exactOutputSingle(
            IBinSwapRouterBase.V4BinExactOutputSingleParams({
                poolKey: key,
                swapForY: swapForY,
                recipient: alice,
                amountOut: 0.5 ether,
                amountInMaximum: 1 ether,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );
        snapEnd();

        assertEq(amountIn, 501504513540621866);
        if (swapForY) {
            assertEq(token0.balanceOf(alice), 1 ether - amountIn);
            assertEq(token1.balanceOf(alice), 0.5 ether);
        } else {
            assertEq(token0.balanceOf(alice), 0.5 ether);
            assertEq(token1.balanceOf(alice), 1 ether - amountIn);
        }
    }

    function testExactOutputSingle_DifferentRecipient() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        snapStart("BinSwapRouterTest#testExactOutputSingle_DifferentRecipient");
        uint256 amountIn = router.exactOutputSingle(
            IBinSwapRouterBase.V4BinExactOutputSingleParams({
                poolKey: key,
                swapForY: true,
                recipient: bob,
                amountOut: 0.5 ether,
                amountInMaximum: 1 ether,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );
        snapEnd();

        assertEq(token0.balanceOf(alice), 1 ether - amountIn);
        assertEq(token1.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(bob), 0.5 ether);
    }

    function testExactOutputSingle_Deadline() public {
        vm.startPrank(alice);

        token0.mint(alice, 1 ether);
        vm.warp(1000); // set block.timestamp

        vm.expectRevert(abi.encodeWithSelector(PeripheryValidation.TransactionTooOld.selector));
        router.exactOutputSingle(
            IBinSwapRouterBase.V4BinExactOutputSingleParams({
                poolKey: key,
                swapForY: true,
                recipient: bob,
                amountOut: 0.5 ether,
                amountInMaximum: 1 ether,
                hookData: new bytes(0)
            }),
            block.timestamp - 100 // timestamp required
        );
    }

    function testExactOutputSingle_AmountInMax() public {
        vm.startPrank(alice);

        // Give alice > amountInMax so TooMuchRequestedError instead of TransferFromFailed
        token0.mint(alice, 2 ether);

        vm.expectRevert(abi.encodeWithSelector(ISwapRouterBase.TooMuchRequested.selector));
        router.exactOutputSingle(
            IBinSwapRouterBase.V4BinExactOutputSingleParams({
                poolKey: key,
                swapForY: true,
                recipient: bob,
                amountOut: 1 ether,
                amountInMaximum: 1 ether, // for 1 eth amountOut, amountIn would be > 1 ether
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );
    }

    function testExactOutputSingle_TooLittleReceived() public {
        //todo: in order to simulate this error, require
        //     // 1. hooks at beforeSwap do something funny on the pool resulting in actual amountOut lesser
    }

    function testExactOutput_SingleHop() public {
        // swap token0 input -> token1 output
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](1);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        // before test validation
        assertEq(token0.balanceOf(alice), 1 ether);
        assertEq(token1.balanceOf(alice), 0);

        snapStart("BinSwapRouterTest#testExactOutput_SingleHop");
        uint256 amountIn = router.exactOutput(
            IBinSwapRouterBase.V4BinExactOutputParams({
                currencyOut: Currency.wrap(address(token1)),
                path: path,
                recipient: alice,
                amountOut: 0.5 ether,
                amountInMaximum: 1 ether
            }),
            block.timestamp + 60
        );
        snapEnd();

        // after test validation
        assertEq(amountIn, 501504513540621866); // amt in should be greater than 0.5 eth
        assertEq(token0.balanceOf(alice), 1 ether - amountIn);
        assertEq(token1.balanceOf(alice), 0.5 ether);
    }

    function testExactOutput_MultiHopDifferentRecipient() public {
        // swap token0 input -> token1 -> token2 output
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](2);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });
        path[1] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key2.fee,
            hooks: key2.hooks,
            hookData: new bytes(0),
            poolManager: key2.poolManager,
            parameters: key2.parameters
        });

        // before test validation
        assertEq(token0.balanceOf(alice), 1 ether);
        assertEq(token1.balanceOf(alice), 0);
        assertEq(token2.balanceOf(alice), 0);
        assertEq(token2.balanceOf(bob), 0 ether);

        snapStart("BinSwapRouterTest#testExactOutput_MultiHopDifferentRecipient");
        uint256 amountIn = router.exactOutput(
            IBinSwapRouterBase.V4BinExactOutputParams({
                currencyOut: Currency.wrap(address(token2)),
                path: path,
                recipient: bob,
                amountOut: 0.5 ether,
                amountInMaximum: 1 ether
            }),
            block.timestamp + 60
        );
        snapEnd();

        // after test validation
        // amt in should be greater than 0.5 eth + 0.3% fee twice (2 pool)
        assertEq(amountIn, 503013554203231561);
        assertEq(token0.balanceOf(alice), 1 ether - amountIn);
        assertEq(token2.balanceOf(bob), 0.5 ether);
    }

    function testExactOutput_Deadline() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);
        vm.warp(1000); // set block.timestamp

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](0);
        vm.expectRevert(abi.encodeWithSelector(PeripheryValidation.TransactionTooOld.selector));
        router.exactOutput(
            IBinSwapRouterBase.V4BinExactOutputParams({
                currencyOut: Currency.wrap(address(token1)),
                path: path,
                recipient: alice,
                amountOut: 0.5 ether,
                amountInMaximum: 1 ether
            }),
            block.timestamp - 100 // timestamp expired
        );
    }

    function testExactOutput_TooMuchRequested() public {
        vm.startPrank(alice);
        token0.mint(alice, 2 ether);

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](1);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        vm.expectRevert(abi.encodeWithSelector(ISwapRouterBase.TooMuchRequested.selector));
        router.exactOutput(
            IBinSwapRouterBase.V4BinExactOutputParams({
                currencyOut: Currency.wrap(address(token1)),
                path: path,
                recipient: alice,
                amountOut: 1 ether,
                amountInMaximum: 1 ether // amountIn is insufficient to get 1 eth out
            }),
            block.timestamp + 60
        );
    }

    function testMulticall_ExactInputRefundEth() public {
        // swap ETH to token0 and refund left over ETH
        vm.startPrank(alice);

        vm.deal(alice, 2 ether);
        assertEq(alice.balance, 2 ether);
        assertEq(token0.balanceOf(alice), 0 ether);

        // swap 1 ETH for token0 and call refundEth
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(
            router.exactInputSingle.selector,
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key3,
                swapForY: true, // swap ETH for token0
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );
        data[1] = abi.encodeWithSelector(router.refundETH.selector);

        bytes[] memory result = new bytes[](2);
        result = router.multicall{value: 2 ether}(data);

        assertEq(alice.balance, 1 ether);
        assertEq(address(router).balance, 0 ether);
        assertEq(token0.balanceOf(alice), abi.decode(result[0], (uint256)));
    }
}
