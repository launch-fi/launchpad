// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {TokenFixture} from "pancake-v4-core/test/helpers/TokenFixture.sol";
import {ICLPoolManager, CLPosition} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import {FixedPoint128} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint128.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "pancake-v4-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {NonfungibleTokenPositionDescriptorOffChain} from
    "../../src/pool-cl/NonfungibleTokenPositionDescriptorOffChain.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {NonfungiblePositionManager} from "../../src/pool-cl/NonfungiblePositionManager.sol";
import {INonfungiblePositionManager} from "../../src/pool-cl/interfaces/INonfungiblePositionManager.sol";
import {LiquidityAmounts} from "../../src/pool-cl/libraries/LiquidityAmounts.sol";
import {LiquidityManagement} from "../../src/pool-cl/base/LiquidityManagement.sol";

contract NonFungiblePositionManagerTest is TokenFixture, Test, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using Strings for uint256;

    event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);

    IVault public vault;
    ICLPoolManager public poolManager;
    CLPoolManagerRouter public router;
    NonfungiblePositionManager public nonfungiblePoolManager;

    function setUp() public {
        vault = new Vault();
        poolManager = new CLPoolManager(vault, 3000);
        vault.registerApp(address(poolManager));

        initializeTokens();

        router = new CLPoolManagerRouter(vault, poolManager);
        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        NonfungibleTokenPositionDescriptorOffChain NFTPositionDescriptorContract =
            new NonfungibleTokenPositionDescriptorOffChain();
        ProxyAdmin proxyAdminContract = new ProxyAdmin();

        string memory baseTokenURI = string.concat("https://nft.pancakeswap.com/v4/", block.chainid.toString(), "/");
        TransparentUpgradeableProxy NFTDescriptorProxy = new TransparentUpgradeableProxy(
            address(NFTPositionDescriptorContract),
            address(proxyAdminContract),
            abi.encodeCall(NonfungibleTokenPositionDescriptorOffChain.initialize, (baseTokenURI))
        );

        nonfungiblePoolManager =
            new NonfungiblePositionManager(vault, poolManager, address(NFTDescriptorProxy), address(0));
        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");

        IERC20(Currency.unwrap(currency0)).approve(address(nonfungiblePoolManager), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(nonfungiblePoolManager), type(uint256).max);
    }

    function testPositions() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        {
            INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: 46053,
                tickUpper: 46055,
                salt: bytes32(0),
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: makeAddr("someone"),
                deadline: type(uint256).max
            });

            uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
            // poolManager.initialize(key, sqrtPriceX96, new bytes(0));
            nonfungiblePoolManager.initialize(key, sqrtPriceX96, new bytes(0));
            // (, int24 tick,,,) = poolManager.getSlot0(key.toId());
            // price = 100 i.e. tick 46054
            // console2.log("tick", tick);
            nonfungiblePoolManager.mint(mintParams);

            // make the LPing balance of the position non-zero
            router.donate(key, 1 ether, 1 ether, "");

            // mint another position in the same price range but different recipient
            INonfungiblePositionManager.MintParams memory mintParams2 = mintParams;
            mintParams2.recipient = address(this);
            nonfungiblePoolManager.mint(mintParams2);

            // mint another position in the same price range but different salt
            INonfungiblePositionManager.MintParams memory mintParams3 = mintParams;
            mintParams3.salt = bytes32(uint256(0xABCD));
            nonfungiblePoolManager.mint(mintParams3);
        }

        {
            (
                uint96 nonce,
                address operator,
                Currency _currency0,
                Currency _currency1,
                uint24 fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1,
                bytes32 salt
            ) = nonfungiblePoolManager.positions(1);
            assertEq(nonce, 0, "Unexpected nonce");
            assertEq(operator, address(0), "Unexpected operator");
            assertEq(Currency.unwrap(_currency0), Currency.unwrap(currency0), "Unexpected currency0");
            assertEq(Currency.unwrap(_currency1), Currency.unwrap(currency1), "Unexpected currency1");
            assertEq(fee, 3000, "Unexpected fee");
            assertEq(tickLower, 46053, "Unexpected tickLower");
            assertEq(tickUpper, 46055, "Unexpected tickUpper");
            assertEq(liquidity, 1991375027067913587988, "Unexpected liquidity");
            assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
            assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
            assertEq(tokensOwed0, 0, "Unexpected tokensOwed0");
            assertEq(tokensOwed1, 0, "Unexpected tokensOwed1");
            assertEq(salt, bytes32(0), "Unexpected salt");
            string memory expectTokenURI =
                string.concat("https://nft.pancakeswap.com/v4/", block.chainid.toString(), "/1");
            string memory realTokenURI = nonfungiblePoolManager.tokenURI(1);
            assertEq(expectTokenURI, realTokenURI, "Unexpected tokenURI");
        }
        {
            (
                uint96 nonce,
                address operator,
                Currency _currency0,
                Currency _currency1,
                uint24 fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1,
                bytes32 salt
            ) = nonfungiblePoolManager.positions(2);
            assertEq(nonce, 0, "Unexpected nonce");
            assertEq(operator, address(0), "Unexpected operator");
            assertEq(Currency.unwrap(_currency0), Currency.unwrap(currency0), "Unexpected currency0");
            assertEq(Currency.unwrap(_currency1), Currency.unwrap(currency1), "Unexpected currency1");
            assertEq(fee, 3000, "Unexpected fee");
            assertEq(tickLower, 46053, "Unexpected tickLower");
            assertEq(tickUpper, 46055, "Unexpected tickUpper");
            assertEq(liquidity, 1991375027067913587988, "Unexpected liquidity");
            // after donation, the feeGrowthInside0LastX128 and feeGrowthInside1LastX128 should be synced
            assertEq(
                feeGrowthInside0LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside0LastX128"
            );
            assertEq(
                feeGrowthInside1LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside1LastX128"
            );
            assertEq(tokensOwed0, 0, "Unexpected tokensOwed0");
            assertEq(tokensOwed1, 0, "Unexpected tokensOwed1");
            assertEq(salt, bytes32(0), "Unexpected salt");
        }

        {
            (
                uint96 nonce,
                address operator,
                Currency _currency0,
                Currency _currency1,
                uint24 fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1,
                bytes32 salt
            ) = nonfungiblePoolManager.positions(3);
            assertEq(nonce, 0, "Unexpected nonce");
            assertEq(operator, address(0), "Unexpected operator");
            assertEq(Currency.unwrap(_currency0), Currency.unwrap(currency0), "Unexpected currency0");
            assertEq(Currency.unwrap(_currency1), Currency.unwrap(currency1), "Unexpected currency1");
            assertEq(fee, 3000, "Unexpected fee");
            assertEq(tickLower, 46053, "Unexpected tickLower");
            assertEq(tickUpper, 46055, "Unexpected tickUpper");
            assertEq(liquidity, 1991375027067913587988, "Unexpected liquidity");
            assertEq(
                feeGrowthInside0LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside0LastX128"
            );
            assertEq(
                feeGrowthInside1LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside1LastX128"
            );
            assertEq(tokensOwed0, 0, "Unexpected tokensOwed0");
            assertEq(tokensOwed1, 0, "Unexpected tokensOwed1");
            assertEq(salt, bytes32(uint256(0xABCD)), "Unexpected salt");
            string memory expectTokenURI =
                string.concat("https://nft.pancakeswap.com/v4/", block.chainid.toString(), "/3");
            string memory realTokenURI = nonfungiblePoolManager.tokenURI(3);
            assertEq(expectTokenURI, realTokenURI, "Unexpected tokenURI");
        }

        // modifyPosition 0 to refresh position(1)'s LPing
        vm.prank(makeAddr("someone"));
        nonfungiblePoolManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: 1,
                amount0Desired: 0,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );

        {
            (
                uint96 nonce,
                address operator,
                Currency _currency0,
                Currency _currency1,
                uint24 fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1,
            ) = nonfungiblePoolManager.positions(1);
            assertEq(nonce, 0, "Unexpected nonce");
            assertEq(operator, address(0), "Unexpected operator");
            assertEq(Currency.unwrap(_currency0), Currency.unwrap(currency0), "Unexpected currency0");
            assertEq(Currency.unwrap(_currency1), Currency.unwrap(currency1), "Unexpected currency1");
            assertEq(fee, 3000, "Unexpected fee");
            assertEq(tickLower, 46053, "Unexpected tickLower");
            assertEq(tickUpper, 46055, "Unexpected tickUpper");
            assertEq(liquidity, 1991375027067913587988, "Unexpected liquidity");
            // after donation, the feeGrowthInside0LastX128 and feeGrowthInside1LastX128 should be synced
            assertEq(
                feeGrowthInside0LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside0LastX128"
            );
            assertEq(
                feeGrowthInside1LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside1LastX128"
            );

            // 9.99 * 1e17 roughly 1 ether
            assertEq(tokensOwed0, 999999999999999999, "Unexpected tokensOwed0");
            assertEq(tokensOwed1, 999999999999999999, "Unexpected tokensOwed1");

            // precision loss caused when calculating feesOwed0 and feesOwed1
            // ref from CLPosition.update
            // feesOwed0 = FullMath.mulDiv(
            //     feeGrowthInside0X128 - _self.feeGrowthInside0LastX128, _self.liquidity, FixedPoint128.Q128
            // );
            assertEq(
                FullMath.mulDiv(feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128),
                tokensOwed0,
                "Unexpected tokensOwed0"
            );
        }

        assertEq(vault.balanceOf(address(nonfungiblePoolManager), currency0), 999999999999999999);
        assertEq(vault.balanceOf(address(nonfungiblePoolManager), currency1), 999999999999999999);
    }

    function testMint(bytes32 salt) external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        int24 tickLower = 46053;
        int24 tickUpper = 46055;
        uint256 amount0Desired = 1 ether;
        uint256 amount1Desired = 2 ether;

        {
            uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
            poolManager.initialize(key, sqrtPriceX96, new bytes(0));

            uint128 liquidityExpected = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                amount0Desired,
                amount1Desired
            );

            vm.expectEmit(true, true, true, false);
            emit IncreaseLiquidity(1, liquidityExpected, 0, 0);
        }

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = nonfungiblePoolManager.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: tickLower,
                tickUpper: tickUpper,
                salt: salt,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: type(uint256).max
            })
        );

        // token consumed
        {
            uint256 token0Left = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Left = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // 1.982e16 roughly 0.02 ether
            assertEq(1000 ether - token0Left, 19824513708386292, "Unexpected currency0 consumed");
            assertEq(amount0, 19824513708386292, "Actual consumed currency0 mismatch");
            // 1e18 i.e. 2 ether, make sense because price is 100
            assertEq(1000 ether - token1Left, 2000000000000000000, "Unexpected currency1 consumed");
            assertEq(amount1, 2000000000000000000, "Actual consumed currency1 mismatch");
        }

        // tick lower and tick upper and salt
        {
            (,,,,, int24 _tickLower, int24 _tickUpper,,,,,, bytes32 _salt) = nonfungiblePoolManager.positions(1);
            assertEq(_tickLower, tickLower, "Unexpected tickLower");
            assertEq(_tickUpper, tickUpper, "Unexpected tickUpper");
            assertEq(_salt, salt, "Unexpected salt");
        }

        // token id starts from 1
        assertEq(tokenId, 1, "Unexpected tokenId");

        assertEq(liquidity, 3982750054135827175977, "Liquidity from mint and liquidity from raw calculation mismatch");
        assertEq(poolManager.getLiquidity(key.toId()), 3982750054135827175977, "Unexpected liquidity for the pool");
        assertEq(
            poolManager.getLiquidity(key.toId(), address(nonfungiblePoolManager), 46053, 46055, salt),
            3982750054135827175977,
            "Unexpected liquidity for current position"
        );

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)), 1, "Unexpected balance of the position owner after mint"
        );

        assertEq(nonfungiblePoolManager.ownerOf(tokenId), address(this), "Unexpected owner of the position");
    }

    function testMint_gas() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        int24 tickLower = 46053;
        int24 tickUpper = 46055;
        uint256 amount0Desired = 1 ether;
        uint256 amount1Desired = 2 ether;

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        snapStart("NonfungiblePositionManager#mint");
        nonfungiblePoolManager.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: tickLower,
                tickUpper: tickUpper,
                salt: bytes32(0),
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: type(uint256).max
            })
        );
        snapEnd();
    }

    function testMint_multiPositionsInSamePriceRange() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: makeAddr("someone"),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        // (, int24 tick,,,) = poolManager.getSlot0(key.toId());
        // price = 100 i.e. tick 46054
        // console2.log("tick", tick);

        // make the LPing balance of the position non-zero
        nonfungiblePoolManager.mint(mintParams);
        router.donate(key, 1 ether, 1 ether, "");

        uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        INonfungiblePositionManager.MintParams memory mintParams2 = mintParams;
        mintParams2.recipient = address(this);
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) =
            nonfungiblePoolManager.mint(mintParams2);

        uint256 token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 token1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // 9.912e15 roughly 0.01 ether
        assertEq(token0Before - token0After, 9912256854193146, "Unexpected currency0 consumed");
        assertEq(amount0, 9912256854193146, "Actual consumed currency0 mismatch");
        // 1e18 i.e. 1 ether, make sense because price is 100
        assertEq(token1Before - token1After, 1000000000000000000, "Unexpected currency1 consumed");
        assertEq(amount1, 1000000000000000000, "Actual consumed currency1 mismatch");

        // start from 1
        assertEq(tokenId, 2, "Unexpected tokenId");

        assertEq(liquidity, 1991375027067913587988, "Liquidity from mint and liquidity from raw calculation mismatch");
        assertEq(poolManager.getLiquidity(key.toId()), 2 * 1991375027067913587988, "Unexpected liquidity for the pool");
        assertEq(
            poolManager.getLiquidity(key.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(0)),
            1991375027067913587988 * 2,
            "Unexpected liquidity for current position"
        );

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)), 1, "Unexpected balance of the position owner after mint"
        );

        assertEq(nonfungiblePoolManager.ownerOf(tokenId), address(this), "Unexpected owner of the position");

        // mint another position in the same price range but different salt
        INonfungiblePositionManager.MintParams memory mintParams3 = mintParams;
        mintParams3.salt = bytes32(uint256(0xABCD));
        nonfungiblePoolManager.mint(mintParams3);

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)),
            2,
            "Unexpected balance of the position owner after mint again"
        );

        // make sure total liquidity is correct
        assertEq(poolManager.getLiquidity(key.toId()), 3 * 1991375027067913587988, "Unexpected liquidity for the pool");

        // make sure liquidity for each position is correct
        assertEq(
            poolManager.getLiquidity(
                key.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(uint256(0xABCD))
            ),
            1991375027067913587988,
            "Unexpected liquidity for current position"
        );
    }

    function testMint_slippage() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            // price 100, the rough ratio is 1:100
            // hence setting both amount0Min and amount1Min to 1 ether will cause slippage check failed
            amount0Min: 1 ether,
            amount1Min: 1 ether,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        vm.expectRevert(LiquidityManagement.PriceSlippageCheckFailed.selector);
        nonfungiblePoolManager.mint(mintParams);
    }

    function testMint_SamePersonMintTokensInSamePriceRange() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        // (, int24 tick,,,) = poolManager.getSlot0(key.toId());
        // price = 100 i.e. tick 46054
        // console2.log("tick", tick);

        // make the LPing balance of the position non-zero
        nonfungiblePoolManager.mint(mintParams);
        router.donate(key, 1 ether, 1 ether, "");

        uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = nonfungiblePoolManager.mint(mintParams);

        uint256 token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 token1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // 9.912e15 roughly 0.01 ether
        assertEq(token0Before - token0After, 9912256854193146, "Unexpected currency0 consumed");
        assertEq(amount0, 9912256854193146, "Actual consumed currency0 mismatch");
        // 1e18 i.e. 1 ether, make sense because price is 100
        assertEq(token1Before - token1After, 1000000000000000000, "Unexpected currency1 consumed");
        assertEq(amount1, 1000000000000000000, "Actual consumed currency1 mismatch");

        // start from 1
        assertEq(tokenId, 2, "Unexpected tokenId");

        assertEq(liquidity, 1991375027067913587988, "Liquidity from mint and liquidity from raw calculation mismatch");
        assertEq(poolManager.getLiquidity(key.toId()), 2 * 1991375027067913587988, "Unexpected liquidity for the pool");
        assertEq(
            poolManager.getLiquidity(key.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(0)),
            1991375027067913587988 * 2,
            "Unexpected liquidity for current position"
        );

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)), 2, "Unexpected balance of the position owner after mint"
        );
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this), "Unexpected owner of the position");
        assertEq(nonfungiblePoolManager.ownerOf(2), address(this), "Unexpected owner of the position");

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
        ) = nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
        assertEq(tokensOwed0, 0, "Unexpected tokensOwed0");
        assertEq(tokensOwed1, 0, "Unexpected tokensOwed1");

        (,,,,,,, _liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwed0, tokensOwed1,) =
            nonfungiblePoolManager.positions(2);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        // after donation, the feeGrowthInside0LastX128 and feeGrowthInside1LastX128 should be synced
        assertEq(feeGrowthInside0LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside1LastX128");
        assertEq(tokensOwed0, 0, "Unexpected tokensOwed0");
        assertEq(tokensOwed1, 0, "Unexpected tokensOwed1");
    }

    function testIncreaseLiquidity(bytes32 salt) external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: salt,
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        nonfungiblePoolManager.mint(mintParams);

        {
            (
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint128 _liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1,
            ) = nonfungiblePoolManager.positions(1);
            assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
            assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
            assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
            assertEq(tokensOwed0, 0, "Unexpected feesOwed0");
            assertEq(tokensOwed1, 0, "Unexpected feesOwed1");
        }

        {
            uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            uint128 liquidityExpected = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, TickMath.getSqrtRatioAtTick(46053), TickMath.getSqrtRatioAtTick(46055), 1 ether, 1 ether
            );

            vm.expectEmit(true, true, true, true);
            emit IncreaseLiquidity(1, liquidityExpected, 9912256854193146, 1000000000000000000);

            // adding into exactly the same position
            (uint128 liquidity, uint256 amount0, uint256 amount1) = nonfungiblePoolManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: 1,
                    amount0Desired: 1 ether,
                    amount1Desired: 1 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: type(uint256).max
                })
            );

            uint256 token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // 9.912e15 roughly 0.01 ether
            assertEq(token0Before - token0After, 9912256854193146, "Unexpected currency0 consumed");
            assertEq(amount0, 9912256854193146, "Actual consumed currency0 mismatch");
            // 1e18 i.e. 1 ether, make sense because price is 100
            assertEq(token1Before - token1After, 1000000000000000000, "Unexpected currency1 consumed");
            assertEq(amount1, 1000000000000000000, "Actual consumed currency1 mismatch");

            assertEq(
                liquidity, 1991375027067913587988, "Liquidity from mint and liquidity from raw calculation mismatch"
            );
        }

        assertEq(poolManager.getLiquidity(key.toId()), 2 * 1991375027067913587988, "Unexpected liquidity for the pool");
        assertEq(
            poolManager.getLiquidity(key.toId(), address(nonfungiblePoolManager), 46053, 46055, salt),
            1991375027067913587988 * 2,
            "Unexpected liquidity for current position"
        );

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)), 1, "Unexpected balance of the position owner after mint"
        );

        assertEq(nonfungiblePoolManager.ownerOf(1), address(this), "Unexpected owner of the position");

        {
            (
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint128 _liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1,
            ) = nonfungiblePoolManager.positions(1);
            assertEq(_liquidity, 1991375027067913587988 * 2, "Unexpected liquidity");
            assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
            assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
            assertEq(tokensOwed0, 0, "Unexpected tokensOwed0");
            assertEq(tokensOwed1, 0, "Unexpected tokensOwed1");
        }
    }

    function testIncreaseLiquidity_gas() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        nonfungiblePoolManager.mint(mintParams);

        snapStart("NonfungiblePositionManager#increaseLiquidity");
        nonfungiblePoolManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: 1,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        snapEnd();
    }

    function testIncreaseLiquidity_AccumulatedLPing() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        nonfungiblePoolManager.mint(mintParams);

        {
            (
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint128 _liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1,
            ) = nonfungiblePoolManager.positions(1);
            assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
            assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
            assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
            assertEq(tokensOwed0, 0, "Unexpected feesOwed0");
            assertEq(tokensOwed1, 0, "Unexpected feesOwed1");
        }

        router.donate(key, 1 ether, 1 ether, "");
        {
            uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            uint128 liquidityExpected = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, TickMath.getSqrtRatioAtTick(46053), TickMath.getSqrtRatioAtTick(46055), 1 ether, 1 ether
            );

            vm.expectEmit(true, true, true, true);
            emit IncreaseLiquidity(1, liquidityExpected, 9912256854193146, 1000000000000000000);

            // adding into exactly the same position
            (uint128 liquidity, uint256 amount0, uint256 amount1) = nonfungiblePoolManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: 1,
                    amount0Desired: 1 ether,
                    amount1Desired: 1 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: type(uint256).max
                })
            );

            uint256 token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // 9.912e15 roughly 0.01 ether
            assertEq(token0Before - token0After, 9912256854193146, "Unexpected currency0 consumed");
            assertEq(amount0, 9912256854193146, "Actual consumed currency0 mismatch");
            // 1e18 i.e. 1 ether, make sense because price is 100
            assertEq(token1Before - token1After, 1000000000000000000, "Unexpected currency1 consumed");
            assertEq(amount1, 1000000000000000000, "Actual consumed currency1 mismatch");

            assertEq(
                liquidity, 1991375027067913587988, "Liquidity from mint and liquidity from raw calculation mismatch"
            );
        }

        assertEq(poolManager.getLiquidity(key.toId()), 2 * 1991375027067913587988, "Unexpected liquidity for the pool");
        assertEq(
            poolManager.getLiquidity(key.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(0)),
            1991375027067913587988 * 2,
            "Unexpected liquidity for current position"
        );

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)), 1, "Unexpected balance of the position owner after mint"
        );

        assertEq(nonfungiblePoolManager.ownerOf(1), address(this), "Unexpected owner of the position");

        {
            (
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint128 _liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1,
            ) = nonfungiblePoolManager.positions(1);
            assertEq(_liquidity, 1991375027067913587988 * 2, "Unexpected liquidity");
            assertEq(
                feeGrowthInside0LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside0LastX128"
            );
            assertEq(
                feeGrowthInside1LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside1LastX128"
            );
            assertEq(tokensOwed0, 999999999999999999, "Unexpected tokensOwed0");
            assertEq(tokensOwed1, 999999999999999999, "Unexpected tokensOwed1");
        }
    }

    function testIncreaseLiquidity_forSomeoneElse_noNeedApprove() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: makeAddr("someone"),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        // (, int24 tick,,,) = poolManager.getSlot0(key.toId());
        // price = 100 i.e. tick 46054
        // console2.log("tick", tick);
        nonfungiblePoolManager.mint(mintParams);

        // adding into exactly the same position
        nonfungiblePoolManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: 1,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    function testIncreaseLiquidity_slippage() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        // (, int24 tick,,,) = poolManager.getSlot0(key.toId());
        // price = 100 i.e. tick 46054
        // console2.log("tick", tick);
        nonfungiblePoolManager.mint(mintParams);

        vm.expectRevert(LiquidityManagement.PriceSlippageCheckFailed.selector);
        nonfungiblePoolManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: 1,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0.01 ether,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    function testDecreaseLiquidity(bytes32 salt) external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: salt,
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
        ) = nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");

        {
            uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            vm.expectEmit(true, true, true, true);
            emit DecreaseLiquidity(1, 1991375027067913587988, 9912256854193145, 999999999999999999);

            (uint256 amount0, uint256 amount1) = nonfungiblePoolManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: 1,
                    liquidity: 1991375027067913587988,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: type(uint256).max
                })
            );

            uint256 token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // 0.01 ether taken out
            assertEq(token0After - token0Before, 9912256854193145, "Unexpected currency0 consumed");
            assertEq(amount0, 9912256854193145, "Actual consumed currency0 mismatch");
            // 0.99 ether taken out
            assertEq(token1After - token1Before, 999999999999999999, "Unexpected currency1 consumed");
            assertEq(amount1, 999999999999999999, "Actual consumed currency1 mismatch");
        }

        assertEq(poolManager.getLiquidity(key.toId()), 0, "Unexpected liquidity for the pool");
        assertEq(
            poolManager.getLiquidity(key.toId(), address(nonfungiblePoolManager), 46053, 46055, salt),
            0,
            "Unexpected liquidity for current position"
        );

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)), 1, "Unexpected balance of the position owner after mint"
        );
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this), "Unexpected owner of the position");

        (,,,,,,, _liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwed0, tokensOwed1,) =
            nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 0, "Unexpected liquidity");
        // after donation, the feeGrowthInside0LastX128 and feeGrowthInside1LastX128 should be synced
        assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
    }

    function testDecreaseLiquidity_gas() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);
        snapStart("NonfungiblePositionManager#decreaseLiquidity");
        nonfungiblePoolManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: 1,
                liquidity: 1991375027067913587988,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
        snapEnd();
    }

    function testDecreaseLiquidity_forSomeoneElse() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: makeAddr("someone"),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);

        vm.expectRevert(INonfungiblePositionManager.NotOwnerOrOperator.selector);
        nonfungiblePoolManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: 1,
                liquidity: 1991375027067913587988,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    function testDecreaseLiquidity_forSomeoneElse_withoutApprove() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: makeAddr("someone"),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);

        vm.prank(makeAddr("someone"));
        nonfungiblePoolManager.approve(address(this), 1);
        nonfungiblePoolManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: 1,
                liquidity: 1991375027067913587988,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    function testDecreaseLiquidity_slippage() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0 ether,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);

        vm.expectRevert(LiquidityManagement.PriceSlippageCheckFailed.selector);
        nonfungiblePoolManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: 1,
                liquidity: 1991375027067913587988,
                // price 100
                amount0Min: 0.01 ether,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );
    }

    function testDecreaseLiquidity_AccumulatedLPing() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        nonfungiblePoolManager.mint(mintParams);
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
        ) = nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
        assertEq(tokensOwed0, 0, "Unexpected feesOwed0");
        assertEq(tokensOwed1, 0, "Unexpected feesOwed1");

        // make the LPing balance of the position non-zero
        router.donate(key, 1 ether, 1 ether, "");

        {
            uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            console2.log("about to decrease liquidity");
            (uint256 amount0, uint256 amount1) = nonfungiblePoolManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: 1,
                    liquidity: 1991375027067913587988,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: type(uint256).max
                })
            );

            uint256 token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // User is expected to receive 0.0099*10^18 roughly 0.01 ether, LPing should not be taken into account
            assertEq(token0After - token0Before, 9912256854193145, "Unexpected currency0 consumed");
            assertEq(amount0, 9912256854193145, "Actual consumed currency0 mismatch");
            // User is expected to receive 0.99*10^18 roughly 1 ether, LPing should not be taken into account
            assertEq(token1After - token1Before, 999999999999999999, "Unexpected currency1 consumed");
            assertEq(amount1, 999999999999999999, "Actual consumed currency1 mismatch");
        }

        assertEq(poolManager.getLiquidity(key.toId()), 0, "Unexpected liquidity for the pool");
        assertEq(
            poolManager.getLiquidity(key.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(0)),
            0,
            "Unexpected liquidity for current position"
        );

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)), 1, "Unexpected balance of the position owner after mint"
        );
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this), "Unexpected owner of the position");

        (,,,,,,, _liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwed0, tokensOwed1,) =
            nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 0, "Unexpected liquidity");
        // after donation, the feeGrowthInside0LastX128 and feeGrowthInside1LastX128 should be synced
        assertEq(feeGrowthInside0LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside1LastX128");
        assertEq(tokensOwed0, 999999999999999999, "Unexpected tokensOwed0");
        assertEq(tokensOwed1, 999999999999999999, "Unexpected tokensOwed1");
    }

    function testBurn() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);

        nonfungiblePoolManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: 1,
                liquidity: 1991375027067913587988,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );

        vm.expectEmit();
        emit Transfer(address(this), address(0), 1);

        (,,,,,,, uint128 liquidity,,,,,) = nonfungiblePoolManager.positions(1);
        assertEq(liquidity, 0, "Unexpected liquidity");

        nonfungiblePoolManager.burn(1);

        vm.expectRevert();
        nonfungiblePoolManager.positions(1);

        vm.expectRevert();
        assertEq(nonfungiblePoolManager.ownerOf(1), address(0), "Unexpected owner of the position");
    }

    function testBurn_gas() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);

        nonfungiblePoolManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: 1,
                liquidity: 1991375027067913587988,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );

        snapStart("NonfungiblePositionManager#burn");
        nonfungiblePoolManager.burn(1);
        snapEnd();
    }

    function testBurn_onBehalfOfSomeoneElse() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: makeAddr("someone"),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        nonfungiblePoolManager.mint(mintParams);

        vm.prank(makeAddr("someone"));
        nonfungiblePoolManager.approve(address(this), 1);

        nonfungiblePoolManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: 1,
                liquidity: 1991375027067913587988,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );

        (,,,,,,, uint128 liquidity,,,,,) = nonfungiblePoolManager.positions(1);
        assertEq(liquidity, 0, "Unexpected liquidity");
        nonfungiblePoolManager.burn(1);

        vm.expectRevert();
        nonfungiblePoolManager.positions(1);

        vm.expectRevert();
        assertEq(nonfungiblePoolManager.ownerOf(1), address(0), "Unexpected owner of the position");
    }

    function testBurn_onBehalfOfSomeoneElse_withoutApprove() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: makeAddr("someone"),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        nonfungiblePoolManager.mint(mintParams);

        vm.prank(makeAddr("someone"));
        nonfungiblePoolManager.approve(address(this), 1);

        nonfungiblePoolManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: 1,
                liquidity: 1991375027067913587988,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );

        // reset
        vm.prank(makeAddr("someone"));
        nonfungiblePoolManager.approve(address(0), 1);
        vm.expectRevert(INonfungiblePositionManager.NotOwnerOrOperator.selector);
        nonfungiblePoolManager.burn(1);
    }

    function testBurn_withNonZeroLiquidity() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);

        nonfungiblePoolManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: 1,
                liquidity: 1991375027067913587988 - 1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );

        (,,,,,,, uint128 liquidity,,,,,) = nonfungiblePoolManager.positions(1);
        assertEq(liquidity, 1, "Unexpected liquidity");

        vm.expectRevert(INonfungiblePositionManager.NonEmptyPosition.selector);
        nonfungiblePoolManager.burn(1);
    }

    function testBurn_withNonZeroLPing() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);

        // make the LPing balance of the position non-zero
        router.donate(key, 1 ether, 1 ether, "");

        nonfungiblePoolManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: 1,
                liquidity: 1991375027067913587988,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );

        (,,,,,,, uint128 liquidity,,,,,) = nonfungiblePoolManager.positions(1);
        assertEq(liquidity, 0, "Unexpected liquidity");

        vm.expectRevert(INonfungiblePositionManager.NonEmptyPosition.selector);
        nonfungiblePoolManager.burn(1);

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)),
            1,
            "Unexpected balance of the position owner after burning failed"
        );
    }

    function testCollect() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);

        // make the LPing balance of the position non-zero
        router.donate(key, 1 ether, 1 ether, "");

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
        ) = nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
        assertEq(tokensOwed0, 0, "Unexpected feesOwed0");
        assertEq(tokensOwed1, 0, "Unexpected feesOwed1");

        {
            uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            vm.expectEmit(true, true, true, true);
            emit Collect(1, address(this), 999999999999999999, 999999999999999999);
            (uint256 amount0, uint256 amount1) = nonfungiblePoolManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: 1,
                    recipient: address(this),
                    amount0Max: 999999999999999999,
                    amount1Max: 999999999999999999
                })
            );

            uint256 token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // 0.01 ether taken out
            assertEq(token0After - token0Before, 999999999999999999, "Unexpected currency0 consumed");
            assertEq(amount0, 999999999999999999, "Actual consumed currency0 mismatch");
            // 0.99 ether taken out
            assertEq(token1After - token1Before, 999999999999999999, "Unexpected currency1 consumed");
            assertEq(amount1, 999999999999999999, "Actual consumed currency1 mismatch");
        }
        assertEq(poolManager.getLiquidity(key.toId()), 1991375027067913587988, "Unexpected liquidity for the pool");
        assertEq(
            poolManager.getLiquidity(key.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(0)),
            1991375027067913587988,
            "Unexpected liquidity for current position"
        );

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)), 1, "Unexpected balance of the position owner after mint"
        );
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this), "Unexpected owner of the position");

        (,,,,,,, _liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwed0, tokensOwed1,) =
            nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        // after donation, the feeGrowthInside0LastX128 and feeGrowthInside1LastX128 should be synced
        assertEq(feeGrowthInside0LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside1LastX128");
        // reset to 0 after collect
        assertEq(tokensOwed0, 0, "Unexpected feesOwed0");
        assertEq(tokensOwed1, 0, "Unexpected feesOwed1");
    }

    function testCollect_positionWithoutLiquidity() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);
        // make the LPing balance of the position non-zero
        router.donate(key, 1 ether, 1 ether, "");

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
        ) = nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
        assertEq(tokensOwed0, 0, "Unexpected feesOwed0");
        assertEq(tokensOwed1, 0, "Unexpected feesOwed1");

        // decrease liquidity to 0
        nonfungiblePoolManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: 1,
                liquidity: _liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );

        (,,,,,,, _liquidity,,,,,) = nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 0, "Unexpected liquidity");

        {
            uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            vm.expectEmit(true, true, true, true);
            emit Collect(1, address(this), 999999999999999999, 999999999999999999);
            (uint256 amount0, uint256 amount1) = nonfungiblePoolManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: 1,
                    recipient: address(this),
                    amount0Max: 999999999999999999,
                    amount1Max: 999999999999999999
                })
            );

            uint256 token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // 0.01 ether taken out
            assertEq(token0After - token0Before, 999999999999999999, "Unexpected currency0 consumed");
            assertEq(amount0, 999999999999999999, "Actual consumed currency0 mismatch");
            // 0.99 ether taken out
            assertEq(token1After - token1Before, 999999999999999999, "Unexpected currency1 consumed");
            assertEq(amount1, 999999999999999999, "Actual consumed currency1 mismatch");
        }

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)), 1, "Unexpected balance of the position owner after mint"
        );
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this), "Unexpected owner of the position");

        (,,,,,,, _liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwed0, tokensOwed1,) =
            nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 0, "Unexpected liquidity");
        // after donation, the feeGrowthInside0LastX128 and feeGrowthInside1LastX128 should be synced
        assertEq(feeGrowthInside0LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside1LastX128");
        // reset to 0 after collect
        assertEq(tokensOwed0, 0, "Unexpected feesOwed0");
        assertEq(tokensOwed1, 0, "Unexpected feesOwed1");
    }

    function testCollect_gas() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);
        // make the LPing balance of the position non-zero
        router.donate(key, 1 ether, 1 ether, "");

        snapStart("NonfungiblePositionManager#collect");
        nonfungiblePoolManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: 1,
                recipient: address(this),
                amount0Max: 999999999999999999,
                amount1Max: 999999999999999999
            })
        );
        snapEnd();
    }

    function testCollect_invalidMaxCollectAmount() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);
        // make the LPing balance of the position non-zero
        router.donate(key, 1 ether, 1 ether, "");

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
        ) = nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
        assertEq(tokensOwed0, 0, "Unexpected feesOwed0");
        assertEq(tokensOwed1, 0, "Unexpected feesOwed1");

        vm.expectRevert(INonfungiblePositionManager.InvalidMaxCollectAmount.selector);
        nonfungiblePoolManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: 1,
                recipient: address(this),
                amount0Max: 0,
                amount1Max: 0
            })
        );
    }

    function testCollect_partialAmount() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);
        // make the LPing balance of the position non-zero
        router.donate(key, 1 ether, 1 ether, "");

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
        ) = nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
        assertEq(tokensOwed0, 0, "Unexpected feesOwed0");
        assertEq(tokensOwed1, 0, "Unexpected feesOwed1");

        {
            uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            vm.expectEmit(true, true, true, true);
            emit Collect(1, address(this), 0.5 ether, 0.5 ether);
            (uint256 amount0, uint256 amount1) = nonfungiblePoolManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: 1,
                    recipient: address(this),
                    amount0Max: 0.5 ether,
                    amount1Max: 0.5 ether
                })
            );

            uint256 token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // exactly 0.5 ether taken out
            assertEq(token0After - token0Before, 0.5 ether, "Unexpected currency0 consumed");
            assertEq(amount0, 0.5 ether, "Actual consumed currency0 mismatch");
            assertEq(token1After - token1Before, 0.5 ether, "Unexpected currency1 consumed");
            assertEq(amount1, 0.5 ether, "Actual consumed currency1 mismatch");
        }
        assertEq(poolManager.getLiquidity(key.toId()), 1991375027067913587988, "Unexpected liquidity for the pool");
        assertEq(
            poolManager.getLiquidity(key.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(0)),
            1991375027067913587988,
            "Unexpected liquidity for current position"
        );

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)), 1, "Unexpected balance of the position owner after mint"
        );
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this), "Unexpected owner of the position");

        (,,,,,,, _liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwed0, tokensOwed1,) =
            nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        // after donation, the feeGrowthInside0LastX128 and feeGrowthInside1LastX128 should be synced
        assertEq(feeGrowthInside0LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside1LastX128");
        // 0.49 ether left
        assertEq(tokensOwed0, 499999999999999999, "Unexpected feesOwed0");
        assertEq(tokensOwed1, 499999999999999999, "Unexpected feesOwed1");
    }

    function testCollect_withRecipientZeroAddr() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);
        // make the LPing balance of the position non-zero
        router.donate(key, 1 ether, 1 ether, "");

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
        ) = nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
        {
            uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            vm.expectEmit(true, true, true, true);
            emit Collect(1, address(this), 999999999999999999, 999999999999999999);
            (uint256 amount0, uint256 amount1) = nonfungiblePoolManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: 1,
                    recipient: address(0),
                    amount0Max: 999999999999999999,
                    amount1Max: 999999999999999999
                })
            );

            uint256 token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            assertEq(token0After - token0Before, 999999999999999999, "Unexpected currency0 received");
            assertEq(amount0, 999999999999999999, "Actual consumed currency0 mismatch");
            assertEq(token1After - token1Before, 999999999999999999, "Unexpected currency1 received");
            assertEq(amount1, 999999999999999999, "Actual consumed currency1 mismatch");
        }

        assertEq(poolManager.getLiquidity(key.toId()), 1991375027067913587988, "Unexpected liquidity for the pool");
        assertEq(
            poolManager.getLiquidity(key.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(0)),
            1991375027067913587988,
            "Unexpected liquidity for current position"
        );

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)), 1, "Unexpected balance of the position owner after mint"
        );
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this), "Unexpected owner of the position");

        (,,,,,,, _liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwed0, tokensOwed1,) =
            nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        // after donation, the feeGrowthInside0LastX128 and feeGrowthInside1LastX128 should be synced
        assertEq(feeGrowthInside0LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside1LastX128");
    }

    function testCollect_forSomeoneElse() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: makeAddr("someone"),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);
        // make the LPing balance of the position non-zero
        router.donate(key, 1 ether, 1 ether, "");

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
        ) = nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");

        {
            uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            vm.prank(makeAddr("someone"));
            nonfungiblePoolManager.approve(address(this), 1);
            vm.expectEmit(true, true, true, true);
            emit Collect(1, makeAddr("someone"), 999999999999999999, 999999999999999999);
            (uint256 amount0, uint256 amount1) = nonfungiblePoolManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: 1,
                    recipient: makeAddr("someone"),
                    amount0Max: 999999999999999999,
                    amount1Max: 999999999999999999
                })
            );

            uint256 token0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
            uint256 token1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

            // 0.01 ether taken out
            assertEq(token0After - token0Before, 0, "Unexpected currency0 consumed");
            assertEq(amount0, 999999999999999999, "Actual consumed currency0 mismatch");
            assertEq(
                IERC20(Currency.unwrap(currency0)).balanceOf(makeAddr("someone")),
                999999999999999999,
                "Unexpected currency0 balance of the recipient"
            );
            assertEq(
                IERC20(Currency.unwrap(currency1)).balanceOf(makeAddr("someone")),
                999999999999999999,
                "Unexpected currency0 balance of the recipient"
            );

            // 0.99 ether taken out
            assertEq(token1After - token1Before, 0, "Unexpected currency1 consumed");
            assertEq(amount1, 999999999999999999, "Actual consumed currency1 mismatch");
        }
        assertEq(poolManager.getLiquidity(key.toId()), 1991375027067913587988, "Unexpected liquidity for the pool");
        assertEq(
            poolManager.getLiquidity(key.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(0)),
            1991375027067913587988,
            "Unexpected liquidity for current position"
        );

        (,,,,,,, _liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwed0, tokensOwed1,) =
            nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 1991375027067913587988, "Unexpected liquidity");
        // after donation, the feeGrowthInside0LastX128 and feeGrowthInside1LastX128 should be synced
        assertEq(feeGrowthInside0LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside0LastX128");
        assertEq(feeGrowthInside1LastX128, 170878092923545294145335173946080448, "Unexpected feeGrowthInside1LastX128");
    }

    function testCollect_forSomeoneElse_withoutApprove() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: makeAddr("someone"),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);

        vm.expectRevert(INonfungiblePositionManager.NotOwnerOrOperator.selector);
        nonfungiblePoolManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: 1,
                recipient: makeAddr("someone"),
                amount0Max: 999999999999999999,
                amount1Max: 999999999999999999
            })
        );
    }

    function testCollect_positionWithoutRewardsAndLiquidity() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);
        nonfungiblePoolManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: 1,
                liquidity: 1991375027067913587988,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );

        nonfungiblePoolManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: 1,
                recipient: address(this),
                amount0Max: 999999999999999999,
                amount1Max: 999999999999999999
            })
        );

        (,,,,,,, uint128 _liquidity,,,,,) = nonfungiblePoolManager.positions(1);
        assertEq(_liquidity, 0, "Unexpected liquidity");
    }

    function testFeeGrowthInsideOnverflow_whenAddLiquidityBackToEmptyPosition() external {
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        // 1. create a position
        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(poolKey, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: poolKey,
                tickLower: 46053,
                tickUpper: 46055,
                salt: bytes32(0),
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: type(uint256).max
            })
        );

        {
            (, int24 tick,,) = poolManager.getSlot0(poolKey.toId());

            // make sure the position is the active
            assertEq(tick, 46054, "Unexpected tick");

            CLPosition.Info memory info =
                poolManager.getPosition(poolKey.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(0));
            assertEq(info.liquidity, 1991375027067913587988, "Unexpected liquidity");
            assertEq(info.feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
            assertEq(info.feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
        }

        // 2. donate to the position so that feeGrowthInside0LastX128 and feeGrowthInside1LastX128 are dirty
        router.donate(poolKey, 1 ether, 1 ether, "");

        // 3. withdraw all liquidity, it's the only position in both ticks so ticks are cleared
        nonfungiblePoolManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: 1,
                liquidity: 1991375027067913587988,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );

        // 4. positionInfo from poolManager with a unzero feeGrowthInside0LastX128 and feeGrowthInside1LastX128
        {
            // non zero feeGrowthInside0LastX128 and feeGrowthInside1LastX128
            CLPosition.Info memory info =
                poolManager.getPosition(poolKey.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(0));
            assertEq(info.liquidity, 0, "Unexpected liquidity");
            assertEq(
                info.feeGrowthInside0LastX128,
                170878092923545294145335173946080448,
                "Unexpected feeGrowthInside0LastX128"
            );
            assertEq(
                info.feeGrowthInside1LastX128,
                170878092923545294145335173946080448,
                "Unexpected feeGrowthInside1LastX128"
            );

            // positionInfo from nonfungiblePoolManager has been synced
            (
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokenOwed0,
                uint128 tokenOwed1,
            ) = nonfungiblePoolManager.positions(1);
            assertEq(info.feeGrowthInside0LastX128, feeGrowthInside0LastX128, "Unexpected feeGrowthInside0LastX128");
            assertEq(info.feeGrowthInside1LastX128, feeGrowthInside1LastX128, "Unexpected feeGrowthInside1LastX128");
            assertEq(tokenOwed0, 999999999999999999, "Unexpected tokenOwed0");
            assertEq(tokenOwed1, 999999999999999999, "Unexpected tokenOwed1");
        }

        // 5. addLiquidity to the position again should not revert and work as expected
        nonfungiblePoolManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: 1,
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                deadline: type(uint256).max
            })
        );

        {
            // non zero feeGrowthInside0LastX128 and feeGrowthInside1LastX128
            CLPosition.Info memory info =
                poolManager.getPosition(poolKey.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(0));
            assertEq(info.liquidity, 1991375027067913587988, "Unexpected liquidity");
            assertEq(info.feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
            assertEq(info.feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");

            // positionInfo from nonfungiblePoolManager has been synced
            (
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokenOwed0,
                uint128 tokenOwed1,
            ) = nonfungiblePoolManager.positions(1);
            assertEq(info.feeGrowthInside0LastX128, feeGrowthInside0LastX128, "Unexpected feeGrowthInside0LastX128");
            assertEq(info.feeGrowthInside1LastX128, feeGrowthInside1LastX128, "Unexpected feeGrowthInside1LastX128");
            assertEq(tokenOwed0, 999999999999999999, "Unexpected tokenOwed0");
            assertEq(tokenOwed1, 999999999999999999, "Unexpected tokenOwed1");
        }
    }

    function testFeeGrowthInsideOnverflow_whenFeeGrowthGlobalNaturallyGoOverflow() external {
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(0),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        // 1. create a position
        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(poolKey, sqrtPriceX96, new bytes(0));

        (, uint128 liquidity1,,) = nonfungiblePoolManager.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: poolKey,
                tickLower: 46053,
                tickUpper: 46055,
                salt: bytes32(0),
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: type(uint256).max
            })
        );

        // decrease liquidity to 1 to better manipulate feeGrowthGlobal
        {
            nonfungiblePoolManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: 1,
                    liquidity: liquidity1 - 1,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: type(uint256).max
                })
            );

            CLPosition.Info memory info =
                poolManager.getPosition(poolKey.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(0));
            assertEq(info.liquidity, 1, "Unexpected liquidity");
        }

        // 2. make sure everything is expected for now
        {
            (, int24 tick,,) = poolManager.getSlot0(poolKey.toId());
            // make sure the position is the active
            assertEq(tick, 46054, "Unexpected tick");

            CLPosition.Info memory info =
                poolManager.getPosition(poolKey.toId(), address(nonfungiblePoolManager), 46053, 46055, bytes32(0));
            assertEq(info.liquidity, 1, "Unexpected liquidity");
            assertEq(info.feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
            assertEq(info.feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
        }

        // 3. donate to the position so that feeGrowthInside0LastX128 and feeGrowthInside1LastX128 are dirty
        mint(type(uint128).max);
        router.donate(poolKey, type(uint128).max / 2, type(uint128).max / 2, "");
        router.donate(poolKey, type(uint128).max / 2, type(uint128).max / 2, "");

        // 4. another position
        // Consuming 1 ether amount0 & 0 ether amount1 because tick lower > active tick
        nonfungiblePoolManager.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: poolKey,
                tickLower: 46055,
                tickUpper: 46058,
                salt: bytes32(0),
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: type(uint256).max
            })
        );

        // 5. swap a bit so that position0(46053, 46055) goes out of range, target tick 46057
        {
            router.swap(
                poolKey,
                ICLPoolManager.SwapParams({
                    zeroForOne: false,
                    // amount1 => amount0
                    amountSpecified: 100 ether,
                    sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(46057)
                }),
                CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
                ""
            );

            (, int24 tick,,) = poolManager.getSlot0(poolKey.toId());
            // make sure the position is the active
            assertEq(tick, 46057, "Tick should be 46057 after swap");
        }

        // decrease liquidity to 1 to better manipulate feeGrowthGlobal for position2
        {
            CLPosition.Info memory info =
                poolManager.getPosition(poolKey.toId(), address(nonfungiblePoolManager), 46055, 46058, bytes32(0));

            nonfungiblePoolManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: 2,
                    liquidity: info.liquidity - 1,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: type(uint256).max
                })
            );

            info = poolManager.getPosition(poolKey.toId(), address(nonfungiblePoolManager), 46055, 46058, bytes32(0));

            assertEq(info.liquidity, 1, "Unexpected liquidity");
        }

        (, uint256 feeGrowthGlobal0X128Before, uint256 feeGrowthGlobal1X128Before,) =
            CLPoolManager(address(poolManager)).pools(poolKey.toId());

        assertEq(
            feeGrowthGlobal0X128Before,
            (type(uint128).max - 1) * FixedPoint128.Q128,
            "feeGrowthGlobal0X128Before already type(uint128) - 1"
        );
        assertEq(
            feeGrowthGlobal1X128Before,
            (type(uint128).max - 1) * FixedPoint128.Q128,
            "feeGrowthGlobal1X128Before already type(uint128) - 1"
        );

        // growthInside = global - outerLower - outerUpper
        // overflow during subtraction is fine but the result i.e. growthInside cant go overflow
        // that's why user must claim rewards before hit that value

        // 7. donate 1 ether so that feeGrowthGlobal goes overflow
        mint(type(uint128).max);
        router.donate(poolKey, 1 ether, 1 ether, "");

        (, uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128,) =
            CLPoolManager(address(poolManager)).pools(poolKey.toId());

        // check overflow did happen
        assertLt(feeGrowthGlobal0X128, feeGrowthGlobal0X128Before, "feeGrowth0 must be decreased since it's overflow");
        assertLt(feeGrowthGlobal1X128, feeGrowthGlobal1X128Before, "feeGrowth1 must be decreased since it's overflow");

        {
            // add(0) to trigger position info sync
            nonfungiblePoolManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: 2,
                    amount0Desired: 0 ether,
                    amount1Desired: 0 ether,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: type(uint256).max
                })
            );

            // tokenOwed are calculated correctly even when overflow happens
            CLPosition.Info memory info =
                poolManager.getPosition(poolKey.toId(), address(nonfungiblePoolManager), 46055, 46058, bytes32(0));
            // positionInfo from nonfungiblePoolManager has been synced
            (
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokenOwed0,
                uint128 tokenOwed1,
            ) = nonfungiblePoolManager.positions(2);
            assertEq(info.feeGrowthInside0LastX128, feeGrowthInside0LastX128, "Unexpected feeGrowthInside0LastX128");
            assertEq(info.feeGrowthInside1LastX128, feeGrowthInside1LastX128, "Unexpected feeGrowthInside1LastX128");
            // 1 ether
            assertEq(tokenOwed0, 1000000000000000000, "Unexpected tokenOwed0");
            assertEq(tokenOwed1, 1000000000000000000, "Unexpected tokenOwed1");
        }
    }
}
