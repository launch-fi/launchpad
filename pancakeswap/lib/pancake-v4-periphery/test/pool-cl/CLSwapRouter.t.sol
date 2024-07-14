// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerRouter} from "pancake-v4-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {CLPool} from "pancake-v4-core/src/pool-cl/libraries/CLPool.sol";

import {TokenFixture} from "../helpers/TokenFixture.sol";

import {CLSwapRouter} from "../../src/pool-cl/CLSwapRouter.sol";
import {ICLSwapRouter} from "../../src/pool-cl/interfaces/ICLSwapRouter.sol";
import {ICLSwapRouterBase} from "../../src/pool-cl/interfaces/ICLSwapRouterBase.sol";
import {ISwapRouterBase} from "../../src/interfaces/ISwapRouterBase.sol";
import {PeripheryValidation} from "../../src/base/PeripheryValidation.sol";

contract CLSwapRouterTest is TokenFixture, Test, GasSnapshot {
    using PoolIdLibrary for PoolKey;

    IVault public vault;
    ICLPoolManager public poolManager;
    CLPoolManagerRouter public positionManager;
    ICLSwapRouter public router;

    PoolKey public poolKey0;
    PoolKey public poolKey1;
    PoolKey public poolKey2;

    function setUp() public {
        WETH weth = new WETH();
        vault = new Vault();
        poolManager = new CLPoolManager(vault, 3000);
        vault.registerApp(address(poolManager));

        initializeTokens();
        vm.label(Currency.unwrap(currency0), "token0");
        vm.label(Currency.unwrap(currency1), "token1");
        vm.label(Currency.unwrap(currency2), "token2");

        positionManager = new CLPoolManagerRouter(vault, poolManager);
        IERC20(Currency.unwrap(currency0)).approve(address(positionManager), 1000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(positionManager), 1000 ether);
        IERC20(Currency.unwrap(currency2)).approve(address(positionManager), 1000 ether);

        router = new CLSwapRouter(vault, poolManager, address(weth));
        IERC20(Currency.unwrap(currency0)).approve(address(router), 1000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 1000 ether);
        IERC20(Currency.unwrap(currency2)).approve(address(router), 1000 ether);

        poolKey0 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });
        // price 100
        uint160 sqrtPriceX96_100 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(poolKey0, sqrtPriceX96_100, new bytes(0));

        positionManager.modifyPosition(
            poolKey0,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: 46053,
                tickUpper: 46055,
                liquidityDelta: 1e4 ether,
                salt: bytes32(0)
            }),
            new bytes(0)
        );

        poolKey1 = PoolKey({
            currency0: currency1,
            currency1: currency2,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });
        // price 1
        uint160 sqrtPriceX96_1 = uint160(1 * FixedPoint96.Q96);
        poolManager.initialize(poolKey1, sqrtPriceX96_1, new bytes(0));

        positionManager.modifyPosition(
            poolKey1,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -5,
                tickUpper: 5,
                liquidityDelta: 1e5 ether,
                salt: bytes32(0)
            }),
            new bytes(0)
        );

        vm.deal(msg.sender, 25 ether);
        poolKey2 = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency0,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });
        // price 1
        uint160 sqrtPriceX96_2 = uint160(1 * FixedPoint96.Q96);

        poolManager.initialize(poolKey2, sqrtPriceX96_2, new bytes(0));

        positionManager.modifyPosition{value: 25 ether}(
            poolKey2,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -5,
                tickUpper: 5,
                liquidityDelta: 1e5 ether,
                salt: bytes32(0)
            }),
            new bytes(0)
        );

        // token0-token1 amount 0.05 ether : 5 ether i.e. price = 100
        // token1-token2 amount 25 ether : 25 ether i.e. price = 1
        // eth-token0 amount 25 ether : 25 ether i.e. price = 1
    }

    function testExactInputSingle_EthPool_zeroForOne() external {
        address alice = makeAddr("alice");
        vm.startPrank(alice);
        vm.deal(alice, 0.01 ether);

        // before assertion
        assertEq(alice.balance, 0.01 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(alice), 0 ether);

        // swap
        uint256 amountOut = router.exactInputSingle{value: 0.01 ether}(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: poolKey2,
                zeroForOne: true,
                recipient: alice,
                amountIn: 0.01 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );

        // after assertion
        assertEq(alice.balance, 0 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(alice), amountOut);
    }

    function testExactInputSingle_EthPool_OneForZero() external {
        // pre-req: mint and approve for alice
        address alice = makeAddr("alice");
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).mint(alice, 0.01 ether);
        IERC20(Currency.unwrap(currency0)).approve(address(router), 0.01 ether);

        // before assertion
        assertEq(alice.balance, 0 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(alice), 0.01 ether);

        // swap
        uint256 amountOut = router.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: poolKey2,
                zeroForOne: false,
                recipient: alice,
                amountIn: 0.01 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );

        // after assertion
        assertEq(alice.balance, amountOut);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(alice), 0);
    }

    function testExactInputSingle_zeroForOne() external {
        uint256 amountOut = router.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: poolKey0,
                zeroForOne: true,
                recipient: makeAddr("recipient"),
                amountIn: 0.01 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );

        uint256 received = IERC20(Currency.unwrap(currency1)).balanceOf(makeAddr("recipient"));
        assertEq(received, amountOut);
        // considering slippage and fee, tolerance is 1%
        assertApproxEqAbs(amountOut, 1 ether, amountOut / 100);
    }

    function testExactInputSingle_oneForZero() external {
        uint256 amountOut = router.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: poolKey0,
                zeroForOne: false,
                recipient: makeAddr("recipient"),
                amountIn: 1 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );

        uint256 received = IERC20(Currency.unwrap(currency0)).balanceOf(makeAddr("recipient"));
        assertEq(received, amountOut);
        // considering slippage and fee, tolerance is 1%
        assertApproxEqAbs(amountOut, 0.01 ether, amountOut / 100);
    }

    function testExactInputSingle_expired() external {
        uint256 deadline = block.timestamp + 100;
        vm.expectRevert(abi.encodeWithSelector(PeripheryValidation.TransactionTooOld.selector));
        skip(200);
        router.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: poolKey0,
                zeroForOne: true,
                recipient: makeAddr("recipient"),
                amountIn: 0.01 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            deadline
        );
    }

    function testExactInputSingle_priceNotMatch() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                CLPool.InvalidSqrtPriceLimit.selector, uint160(10 * FixedPoint96.Q96), uint160(11 * FixedPoint96.Q96)
            )
        );
        router.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: poolKey0,
                zeroForOne: true,
                recipient: makeAddr("recipient"),
                amountIn: 0.01 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: uint160(11 * FixedPoint96.Q96),
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );
    }

    function testExactInputSingle_amountOutLessThanExpected() external {
        vm.expectRevert(ISwapRouterBase.TooLittleReceived.selector);
        router.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: poolKey0,
                zeroForOne: true,
                recipient: makeAddr("recipient"),
                amountIn: 0.01 ether,
                amountOutMinimum: 2 ether,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );
    }

    function testExactInputSingle_gas() external {
        snapStart("CLSwapRouterTest#ExactInputSingle");
        router.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: poolKey0,
                zeroForOne: true,
                recipient: makeAddr("recipient"),
                amountIn: 0.01 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );
        snapEnd();
    }

    function testExactInput() external {
        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](2);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency2,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        uint256 amountOut = router.exactInput(
            ICLSwapRouterBase.V4CLExactInputParams({
                currencyIn: currency0,
                path: path,
                recipient: makeAddr("recipient"),
                amountIn: 0.01 ether,
                amountOutMinimum: 0
            }),
            block.timestamp + 100
        );

        uint256 received = IERC20(Currency.unwrap(currency2)).balanceOf(makeAddr("recipient"));
        assertEq(received, amountOut);
        // considering slippage and fee, tolerance is 1%
        assertApproxEqAbs(amountOut, 1 ether, amountOut / 100);
    }

    function testExactInput_expired() external {
        uint256 deadline = block.timestamp + 100;
        vm.expectRevert(abi.encodeWithSelector(PeripheryValidation.TransactionTooOld.selector));
        skip(200);
        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](2);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency2,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        router.exactInput(
            ICLSwapRouterBase.V4CLExactInputParams({
                currencyIn: currency0,
                path: path,
                recipient: makeAddr("recipient"),
                amountIn: 0.01 ether,
                amountOutMinimum: 0
            }),
            deadline
        );
    }

    function testExactInput_amountOutLessThanExpected() external {
        vm.expectRevert(ISwapRouterBase.TooLittleReceived.selector);
        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](2);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency2,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        router.exactInput(
            ICLSwapRouterBase.V4CLExactInputParams({
                currencyIn: currency0,
                path: path,
                recipient: makeAddr("recipient"),
                amountIn: 0.01 ether,
                amountOutMinimum: 2 ether
            }),
            block.timestamp + 100
        );
    }

    function testExactInput_gasX() external {
        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](2);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency2,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        snapStart("CLSwapRouterTest#ExactInput");
        router.exactInput(
            ICLSwapRouterBase.V4CLExactInputParams({
                currencyIn: currency0,
                path: path,
                recipient: makeAddr("recipient"),
                amountIn: 0.01 ether,
                amountOutMinimum: 0
            }),
            block.timestamp + 100
        );
        snapEnd();
    }

    function testExactOutputSingle_zeroForOne() external {
        uint256 balanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 amountIn = router.exactOutputSingle(
            ICLSwapRouterBase.V4CLExactOutputSingleParams({
                poolKey: poolKey0,
                zeroForOne: true,
                recipient: makeAddr("recipient"),
                amountOut: 1 ether,
                amountInMaximum: 0.0101 ether,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );
        uint256 balanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        uint256 paid = balanceBefore - balanceAfter;
        assertEq(paid, amountIn);
        // considering slippage and fee, tolerance is 1%
        assertApproxEqAbs(amountIn, 0.01 ether, amountIn / 100);
    }

    function testExactOutputSingle_oneForZero() external {
        uint256 balanceBefore = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 amountIn = router.exactOutputSingle(
            ICLSwapRouterBase.V4CLExactOutputSingleParams({
                poolKey: poolKey0,
                zeroForOne: false,
                recipient: makeAddr("recipient"),
                amountOut: 0.01 ether,
                amountInMaximum: 1.01 ether,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );
        uint256 balanceAfter = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        uint256 paid = balanceBefore - balanceAfter;
        assertEq(paid, amountIn);
        // considering slippage and fee, tolerance is 1%
        assertApproxEqAbs(amountIn, 1 ether, amountIn / 100);
    }

    function testExactOutputSingle_expired() external {
        uint256 deadline = block.timestamp + 100;
        vm.expectRevert(abi.encodeWithSelector(PeripheryValidation.TransactionTooOld.selector));
        skip(200);
        router.exactOutputSingle(
            ICLSwapRouterBase.V4CLExactOutputSingleParams({
                poolKey: poolKey0,
                zeroForOne: true,
                recipient: makeAddr("recipient"),
                amountOut: 1 ether,
                amountInMaximum: 0.0101 ether,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            deadline
        );
    }

    function testExactOutputSingle_priceNotMatch() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                CLPool.InvalidSqrtPriceLimit.selector, uint160(10 * FixedPoint96.Q96), uint160(11 * FixedPoint96.Q96)
            )
        );

        router.exactOutputSingle(
            ICLSwapRouterBase.V4CLExactOutputSingleParams({
                poolKey: poolKey0,
                zeroForOne: true,
                recipient: makeAddr("recipient"),
                amountOut: 1 ether,
                amountInMaximum: 0.0101 ether,
                sqrtPriceLimitX96: uint160(11 * FixedPoint96.Q96),
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );
    }

    function testExactOutputSingle_amountOutLessThanExpected() external {
        vm.expectRevert(ISwapRouterBase.TooMuchRequested.selector);

        router.exactOutputSingle(
            ICLSwapRouterBase.V4CLExactOutputSingleParams({
                poolKey: poolKey0,
                zeroForOne: true,
                recipient: makeAddr("recipient"),
                amountOut: 1 ether,
                amountInMaximum: 0.01 ether,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );
    }

    function testExactOutputSingle_gas() external {
        snapStart("CLSwapRouterTest#ExactOutputSingle");
        router.exactOutputSingle(
            ICLSwapRouterBase.V4CLExactOutputSingleParams({
                poolKey: poolKey0,
                zeroForOne: true,
                recipient: makeAddr("recipient"),
                amountOut: 1 ether,
                amountInMaximum: 0.0101 ether,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );
        snapEnd();
    }

    // -------

    function testExactOutput() external {
        uint256 balanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](2);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency0,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        uint256 amountIn = router.exactOutput(
            ICLSwapRouterBase.V4CLExactOutputParams({
                currencyOut: currency2,
                path: path,
                recipient: makeAddr("recipient"),
                amountOut: 1 ether,
                amountInMaximum: 0.0101 ether
            }),
            block.timestamp + 100
        );

        uint256 balanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 paid = balanceBefore - balanceAfter;

        assertEq(paid, amountIn);
        // considering slippage and fee, tolerance is 1%
        assertApproxEqAbs(amountIn, 0.01 ether, amountIn / 100);
    }

    function testExactOutput_expired() external {
        uint256 deadline = block.timestamp + 100;
        vm.expectRevert(abi.encodeWithSelector(PeripheryValidation.TransactionTooOld.selector));
        skip(200);
        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](2);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency0,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        router.exactOutput(
            ICLSwapRouterBase.V4CLExactOutputParams({
                currencyOut: currency2,
                path: path,
                recipient: makeAddr("recipient"),
                amountOut: 1 ether,
                amountInMaximum: 0.0101 ether
            }),
            deadline
        );
    }

    function testExactOutput_amountInMoreThanExpected() external {
        vm.expectRevert(ISwapRouterBase.TooMuchRequested.selector);

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](2);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency0,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        router.exactOutput(
            ICLSwapRouterBase.V4CLExactOutputParams({
                currencyOut: currency2,
                path: path,
                recipient: makeAddr("recipient"),
                amountOut: 1 ether,
                amountInMaximum: 0.01 ether
            }),
            block.timestamp + 100
        );
    }

    function testExactOutput_gas() external {
        snapStart("CLSwapRouterTest#ExactOutput");
        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](2);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency0,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = ISwapRouterBase.PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        router.exactOutput(
            ICLSwapRouterBase.V4CLExactOutputParams({
                currencyOut: currency2,
                path: path,
                recipient: makeAddr("recipient"),
                amountOut: 1 ether,
                amountInMaximum: 0.0101 ether
            }),
            block.timestamp + 100
        );
        snapEnd();
    }

    // allow refund of ETH
    receive() external payable {}
}
