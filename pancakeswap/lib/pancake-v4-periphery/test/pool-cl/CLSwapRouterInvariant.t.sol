// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {SortTokens} from "pancake-v4-core/test/helpers/SortTokens.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {Constants} from "pancake-v4-core/test/pool-cl/helpers/Constants.sol";

import {CLSwapRouter} from "../../src/pool-cl/CLSwapRouter.sol";
import {ICLSwapRouterBase} from "../../src/pool-cl/interfaces/ICLSwapRouterBase.sol";
import {ISwapRouterBase} from "../../src/interfaces/ISwapRouterBase.sol";
import {NonfungiblePositionManager} from "../../src/pool-cl/NonfungiblePositionManager.sol";
import {INonfungiblePositionManager} from "../../src/pool-cl/interfaces/INonfungiblePositionManager.sol";

contract CLSwapRouterHandler is Test {
    using PoolIdLibrary for PoolKey;

    PoolKey public poolKey;
    PoolKey public nativePoolKey;
    IVault public vault;
    CLSwapRouter public router;
    NonfungiblePositionManager public positionManager;
    ICLPoolManager public poolManager;

    address public alice = makeAddr("alice");

    MockERC20 public token0;
    MockERC20 public token1;
    Currency public currency0;
    Currency public currency1;
    uint256 public token0Minted;
    uint256 public token1Minted;
    uint256 public nativeTokenMinted;

    uint256 public token0FeeAccrued;
    uint256 public token1FeeAccrued;

    constructor() {
        WETH weth = new WETH();
        vault = new Vault();
        poolManager = new CLPoolManager(vault, 3000);
        vault.registerApp(address(poolManager));

        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        (token0, token1) = address(token0) > address(token1) ? (token1, token0) : (token0, token1);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // router and position manager
        positionManager = new NonfungiblePositionManager(vault, poolManager, address(0), address(weth));
        router = new CLSwapRouter(vault, poolManager, address(weth));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });
        poolManager.initialize(poolKey, Constants.SQRT_RATIO_1_1, new bytes(0));

        nativePoolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });
        poolManager.initialize(nativePoolKey, Constants.SQRT_RATIO_1_1, new bytes(0));

        vm.startPrank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(positionManager), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(positionManager), type(uint256).max);
        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
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

        vm.recordLogs();

        vm.prank(alice);
        router.exactInputSingle{value: value}(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: pk,
                zeroForOne: true,
                recipient: alice,
                amountIn: amtIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );

        _accumulateFee();
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
        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](1);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: pk.fee,
            hooks: pk.hooks,
            hookData: new bytes(0),
            poolManager: pk.poolManager,
            parameters: pk.parameters
        });

        vm.recordLogs();

        // if native pool, have to ensure call method with value
        uint256 value = isNativePool ? amtIn : 0;
        vm.prank(alice);
        router.exactInput{value: value}(
            ICLSwapRouterBase.V4CLExactInputParams({
                currencyIn: isNativePool ? CurrencyLibrary.NATIVE : currency0,
                path: path,
                recipient: alice,
                amountIn: amtIn,
                amountOutMinimum: 0
            }),
            block.timestamp + 100
        );

        _accumulateFee();
    }

    function exactSwapOutputSingle(uint128 amtIn, bool isNativePool) public {
        amtIn = uint128(bound(amtIn, 10, 100 ether));

        // step 1: Mint token to alice for swap and add liquidity
        _mint(amtIn, isNativePool);

        // Step 2: Mint token for alice to swap
        isNativePool ? vm.deal(alice, amtIn) : token0.mint(alice, amtIn);
        isNativePool ? nativeTokenMinted += amtIn : token0Minted += amtIn;

        // Step 3: swap
        vm.recordLogs();

        PoolKey memory pk = isNativePool ? nativePoolKey : poolKey;
        // if native pool, have to ensure call method with value
        uint256 value = isNativePool ? amtIn : 0;
        vm.prank(alice);
        router.exactOutputSingle{value: value}(
            ICLSwapRouterBase.V4CLExactOutputSingleParams({
                poolKey: pk,
                zeroForOne: true,
                recipient: alice,
                amountOut: amtIn / 2,
                amountInMaximum: amtIn,
                sqrtPriceLimitX96: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 100
        );

        _accumulateFee();
    }

    function exactSwapOutput(uint128 amtIn, bool isNativePool) public {
        amtIn = uint128(bound(amtIn, 10, 100 ether));

        // step 1: Mint token to alice for swap and add liquidity
        _mint(amtIn, isNativePool);

        // Step 2: Mint token for alice to swap
        isNativePool ? vm.deal(alice, amtIn) : token0.mint(alice, amtIn);
        isNativePool ? nativeTokenMinted += amtIn : token0Minted += amtIn;

        // Step 3: swap
        vm.recordLogs();

        PoolKey memory pk = isNativePool ? nativePoolKey : poolKey;
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
        vm.prank(alice);
        router.exactOutput{value: value}(
            ICLSwapRouterBase.V4CLExactOutputParams({
                currencyOut: currency1,
                path: path,
                recipient: alice,
                amountOut: amtIn / 2,
                amountInMaximum: amtIn
            }),
            block.timestamp + 60
        );

        _accumulateFee();
    }

    function _mint(uint128 amt, bool isNativePool) private {
        /// @dev given that amt is cap at 100 ether, we can safely mint 5x the amount to reduce slippage in trading
        amt = amt * 10;

        // step 1: Mint token to alice for add liquidity
        isNativePool ? vm.deal(alice, amt) : token0.mint(alice, amt);
        isNativePool ? nativeTokenMinted += amt : token0Minted += amt;
        token1Minted += amt;
        token1.mint(alice, amt);

        PoolKey memory pk = isNativePool ? nativePoolKey : poolKey;
        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: pk,
            tickLower: -10,
            tickUpper: 10,
            salt: bytes32(0),
            amount0Desired: amt,
            amount1Desired: amt,
            amount0Min: 0,
            amount1Min: 0,
            recipient: alice,
            deadline: block.timestamp
        });

        vm.startPrank(alice);
        if (isNativePool) {
            positionManager.mint{value: amt}(mintParams);
        } else {
            positionManager.mint(mintParams);
        }
        vm.stopPrank();
    }

    function _accumulateFee() private {
        // event Swap(
        //     PoolId indexed id,
        //     address indexed sender,
        //     int128 amount0,
        //     int128 amount1,
        //     uint160 sqrtPriceX96,
        //     uint128 liquidity,
        //     int24 tick,
        //     uint24 fee,
        //     uint256 protocolFee
        // );
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (int128 amount0, int128 amount1,,,,,) =
            abi.decode(entries[0].data, (int128, int128, uint160, uint128, int24, uint24, uint256));

        if (amount0 < 0) {
            // amt0 < 0 means token0 is swapped in, so fee taken from token0
            token0FeeAccrued += uint128(-amount0) * 3000 / 1e6;
        } else {
            // else fee taken from token1
            token1FeeAccrued += uint128(-amount1) * 3000 / 1e6;
        }
    }
}

contract CLSwapRouterInvariant is Test {
    CLSwapRouterHandler _handler;

    function setUp() public {
        // deploy necessary contract
        _handler = new CLSwapRouterHandler();

        // only call CLSwapRouterHandler
        targetContract(address(_handler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = CLSwapRouterHandler.exactSwapInputSingle.selector;
        selectors[1] = CLSwapRouterHandler.exactSwapOutputSingle.selector;
        selectors[2] = CLSwapRouterHandler.exactSwapInput.selector;
        selectors[3] = CLSwapRouterHandler.exactSwapOutput.selector;
        targetSelector(FuzzSelector({addr: address(_handler), selectors: selectors}));
    }

    /// @dev token minted should be either in vault or with alice
    function invariant_AllTokensInVaultOrUser() public view {
        IVault vault = IVault(_handler.vault());

        // token0
        uint256 token0BalInVault = _handler.token0().balanceOf(address(vault));
        uint256 token0WithAlice = _handler.token0().balanceOf(_handler.alice());
        assertEq(token0BalInVault + token0WithAlice, _handler.token0Minted());

        // token1
        uint256 token1BalInVault = _handler.token1().balanceOf(address(vault));
        uint256 token1WithAlice = _handler.token1().balanceOf(_handler.alice());
        assertEq(token1BalInVault + token1WithAlice, _handler.token1Minted());

        // Native ETH case will have spare ETH in router
        uint256 nativeTokenInVault = address(vault).balance;
        uint256 nativeTokenWithAlice = _handler.alice().balance;
        uint256 routerBalance = address(_handler.router()).balance;
        assertEq(nativeTokenInVault + nativeTokenWithAlice + routerBalance, _handler.nativeTokenMinted());
    }

    function invariant_AllSwapFeeGoesToLP() public {
        INonfungiblePositionManager positionManager = INonfungiblePositionManager(_handler.positionManager());

        uint256 positionTokenAmt = positionManager.balanceOf(_handler.alice());

        uint256 realFee0Accrued = 0;
        uint256 realFee1Accrued = 0;
        for (uint256 i = 0; i < positionTokenAmt; i++) {
            uint256 tokenId = positionManager.tokenOfOwnerByIndex(_handler.alice(), i);
            vm.prank(_handler.alice());
            positionManager.approve(address(this), tokenId);
            (uint256 _realFee0Accrued, uint256 _realFee1Accrued) = positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: _handler.alice(),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            realFee0Accrued += _realFee0Accrued;
            realFee1Accrued += _realFee1Accrued;
        }

        /// @dev due to the precision loss, fee accrued might not be exactly the same
        assertLe(_handler.token0FeeAccrued() - realFee0Accrued, 10);
        assertLe(_handler.token1FeeAccrued() - realFee1Accrued, 10);
    }
}
