// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {BinHelper} from "pancake-v4-core/src/pool-bin/libraries/BinHelper.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolManager} from "pancake-v4-core/src/pool-bin/BinPoolManager.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {BinFungiblePositionManager} from "../../src/pool-bin/BinFungiblePositionManager.sol";
import {IBinFungiblePositionManager} from "../../src/pool-bin/interfaces/IBinFungiblePositionManager.sol";
import {LiquidityParamsHelper} from "./helpers/LiquidityParamsHelper.sol";
import {BeforeMintSwapHook} from "./helpers/BeforeMintSwapHook.sol";
import {PeripheryValidation} from "../../src/base/PeripheryValidation.sol";
import {BinTokenLibrary} from "../../src/pool-bin/libraries/BinTokenLibrary.sol";
import {IBinFungibleToken} from "../../src/pool-bin/interfaces/IBinFungibleToken.sol";

contract BinFungiblePositionManager_RemoveLiquidityTest is Test, GasSnapshot, LiquidityParamsHelper {
    using BinPoolParametersHelper for bytes32;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using BinTokenLibrary for PoolId;

    bytes constant ZERO_BYTES = new bytes(0);

    PoolKey key1;
    PoolKey key2;
    Vault vault;
    BinPoolManager poolManager;
    BinFungiblePositionManager binFungiblePositionManager;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    bytes32 poolParam;

    IBinFungiblePositionManager.AddLiquidityParams addParams;
    IBinFungiblePositionManager.RemoveLiquidityParams removeParams;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    event TransferBatch(
        address indexed sender, address indexed from, address indexed to, uint256[] ids, uint256[] amounts
    );
    event OnWithdraw(PoolId id, address user, uint256[] binIds, uint256[] amounts);

    function setUp() public {
        WETH weth = new WETH();
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)), 500000);
        vault.registerApp(address(poolManager));

        binFungiblePositionManager =
            new BinFungiblePositionManager(IVault(address(vault)), IBinPoolManager(address(poolManager)), address(weth));

        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        (currency0, currency1) = currency0 > currency1 ? (currency1, currency0) : (currency0, currency1);
        (token0, token1) = Currency.unwrap(currency0) == address(token0) ? (token0, token1) : (token1, token0);

        key1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(100), // 100 = 0.01%
            parameters: poolParam.setBinStep(10) // binStep
        });

        poolManager.initialize(key1, activeId, ZERO_BYTES);
        poolManager.initialize(key2, activeId, ZERO_BYTES);

        vm.startPrank(alice);
        token0.approve(address(binFungiblePositionManager), 1000 ether);
        token1.approve(address(binFungiblePositionManager), 1000 ether);
        vm.stopPrank();
    }

    function testRemoveLiquidity_BeforeDeadline() public {
        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 3);

        // Pre-req: Add liquidity, 1 eth on each side
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);
        addParams = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        (,,, uint256[] memory liquidityMinted) = binFungiblePositionManager.addLiquidity(addParams);

        // Remove liquidity
        vm.warp(1000);
        removeParams = _getRemoveParams(key1, binIds, liquidityMinted);
        removeParams.deadline = 900; // set deadline before block.timestamp

        vm.expectRevert(abi.encodeWithSelector(PeripheryValidation.TransactionTooOld.selector));
        binFungiblePositionManager.removeLiquidity(removeParams);
    }

    function testRemoveLiquidity_InputLengthMismatch() public {
        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 3);

        // Pre-req: Add liquidity, 1 eth on each side
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);
        addParams = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        (,,, uint256[] memory liquidityMinted) = binFungiblePositionManager.addLiquidity(addParams);

        // amount mismatch
        removeParams = _getRemoveParams(key1, binIds, liquidityMinted);
        removeParams.amounts = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.InputLengthMismatch.selector));
        binFungiblePositionManager.removeLiquidity(removeParams);

        // id mismatch
        removeParams = _getRemoveParams(key1, binIds, liquidityMinted);
        removeParams.ids = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.InputLengthMismatch.selector));
        binFungiblePositionManager.removeLiquidity(removeParams);
    }

    function testRemoveLiquidity_OutputAmountSlippage() public {
        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 3);

        // Pre-req: Add liquidity, 1 eth on each side
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);
        addParams = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        (,,, uint256[] memory liquidityMinted) = binFungiblePositionManager.addLiquidity(addParams);

        // amount0 min slippage
        removeParams = _getRemoveParams(key1, binIds, liquidityMinted);
        removeParams.amount0Min = 2 ether;
        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.OutputAmountSlippage.selector));
        binFungiblePositionManager.removeLiquidity(removeParams);

        // amount1 min slippage
        removeParams = _getRemoveParams(key1, binIds, liquidityMinted);
        removeParams.amount1Min = 2 ether;
        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.OutputAmountSlippage.selector));
        binFungiblePositionManager.removeLiquidity(removeParams);

        // amount and amount0 min slippage
        removeParams = _getRemoveParams(key1, binIds, liquidityMinted);
        removeParams.amount0Min = 2 ether;
        removeParams.amount1Min = 2 ether;
        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.OutputAmountSlippage.selector));
        binFungiblePositionManager.removeLiquidity(removeParams);
    }

    function testRemoveLiquidityWithActiveId_ThreeBins() public {
        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 3);

        // Pre-req: Add liquidity, 1 eth on each side
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);
        addParams = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        (,, uint256[] memory tokenIdsMinted, uint256[] memory liquidityMinted) =
            binFungiblePositionManager.addLiquidity(addParams);

        // check token/nft balance of alice
        assertEq(token0.balanceOf(alice), 0);
        assertEq(token1.balanceOf(alice), 0);
        for (uint256 i; i < tokenIdsMinted.length; i++) {
            assertEq(key1.toId().toTokenId(binIds[i]), tokenIdsMinted[i]);
            assertEq(binFungiblePositionManager.balanceOf(alice, tokenIdsMinted[i]), liquidityMinted[i]);
            assertGt(liquidityMinted[i], 0);
        }

        // Expect emitted events
        uint256[] memory _tokenIds = new uint256[](binIds.length);
        for (uint256 i; i < binIds.length; i++) {
            _tokenIds[i] = key1.toId().toTokenId(binIds[i]);
        }
        vm.expectEmit();
        emit TransferBatch(alice, alice, address(0), _tokenIds, liquidityMinted);

        // remove liquidity
        removeParams = _getRemoveParams(key1, binIds, liquidityMinted);
        snapStart("BinFungiblePositionManager_RemoveLiquidityTest#testRemoveLiquidityWithActiveId_ThreeBins");
        (uint128 amt0, uint128 amt1, uint256[] memory tokenIdsBurnt) =
            binFungiblePositionManager.removeLiquidity(removeParams);
        snapEnd();

        // check token/nft balance of alice
        assertEq(amt0, 1 ether);
        assertEq(amt1, 1 ether);
        assertEq(token0.balanceOf(alice), amt0);
        assertEq(token1.balanceOf(alice), amt1);
        for (uint256 i; i < tokenIdsMinted.length; i++) {
            assertEq(tokenIdsMinted[i], tokenIdsBurnt[i]);
            assertEq(binFungiblePositionManager.balanceOf(alice, tokenIdsMinted[i]), 0);
        }
    }

    function testRemoveLiquidity_Half() public {
        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 3);

        // Pre-req: Add liquidity, 1 eth on each side
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);
        addParams = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        (,, uint256[] memory binIdMinted, uint256[] memory liquidityMinted) =
            binFungiblePositionManager.addLiquidity(addParams);

        // remove 1/2 liquidity
        removeParams = _getRemoveParams(key1, binIds, liquidityMinted);
        for (uint256 i; i < removeParams.amounts.length; i++) {
            removeParams.amounts[i] = liquidityMinted[i] / 2;
        }
        snapStart("BinFungiblePositionManager_RemoveLiquidityTest#testRemoveLiquidity_Half");
        (uint128 amount0, uint128 amount1,) = binFungiblePositionManager.removeLiquidity(removeParams);
        snapEnd();

        // check token/nft balance of alice. should be 1/2 balance left
        assertEq(token0.balanceOf(alice), 1 ether - amount0);
        assertEq(token1.balanceOf(alice), 1 ether - amount1);
        assertApproxEqRel(token0.balanceOf(alice), 0.5 ether, 1e15); // 0.1% precision
        assertApproxEqRel(token1.balanceOf(alice), 0.5 ether, 1e15);
        for (uint256 i; i < binIdMinted.length; i++) {
            uint256 tokenId = key1.toId().toTokenId(binIds[i]); // key1.toBinToken(binIds[i]);
            assertApproxEqRel(binFungiblePositionManager.balanceOf(alice, tokenId), liquidityMinted[i] / 2, 1e15);
        }
    }

    function testRemoveLiquidityOutsideActiveId_ThreeBins() public {
        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId - 10, 2); // all binId to the left

        // Pre-req: Add liquidity
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);
        addParams = _getAddParams(key1, binIds, 0, 1 ether, activeId, alice);
        (,, uint256[] memory tokenIdsMinted, uint256[] memory liquidityMinted) =
            binFungiblePositionManager.addLiquidity(addParams);

        // check token balance of alice
        assertEq(token1.balanceOf(alice), 0 ether);
        for (uint256 i; i < tokenIdsMinted.length; i++) {
            uint256 tokenId = key1.toId().toTokenId(binIds[i]); // key1.toBinToken(binIds[i]);
            assertEq(tokenId, tokenIdsMinted[i]);
            assertEq(binFungiblePositionManager.balanceOf(alice, tokenId), liquidityMinted[i]);
            assertGt(liquidityMinted[i], 0);
        }

        // remove liquidity
        removeParams = _getRemoveParams(key1, binIds, liquidityMinted);
        snapStart("BinFungiblePositionManager_RemoveLiquidityTest#testRemoveLiquidityOutsideActiveId_ThreeBins");
        binFungiblePositionManager.removeLiquidity(removeParams);
        snapEnd();

        // check token balance of alice
        assertEq(token1.balanceOf(alice), 1 ether);
        for (uint256 i; i < tokenIdsMinted.length; i++) {
            assertEq(binFungiblePositionManager.balanceOf(alice, tokenIdsMinted[i]), 0);
        }
    }

    function testRemoveLiquidity_OutputTokenToBob() public {
        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 3);

        // Pre-req: Add liquidity, 1 eth on each side
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);
        addParams = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        (,,, uint256[] memory liquidityMinted) = binFungiblePositionManager.addLiquidity(addParams);

        // check token balance of bob
        assertEq(token0.balanceOf(bob), 0);
        assertEq(token1.balanceOf(bob), 0);

        // amount0 min slippage
        removeParams = _getRemoveParams(key1, binIds, liquidityMinted);
        removeParams.to = bob;
        binFungiblePositionManager.removeLiquidity(removeParams);

        // check token balance of bob
        assertEq(token0.balanceOf(bob), 1 ether);
        assertEq(token1.balanceOf(bob), 1 ether);
    }

    function testRemoveLiquidity_OverBalance() public {
        vm.startPrank(alice);

        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory params;

        // Pre-req key1
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        (,,, uint256[] memory liquidityMinted) = binFungiblePositionManager.addLiquidity(params);

        // remove more than minted, arithemtic as bal goes into negative
        liquidityMinted[0] = liquidityMinted[0] + 1;
        removeParams = _getRemoveParams(key1, binIds, liquidityMinted);
        vm.expectRevert(stdError.arithmeticError);
        binFungiblePositionManager.removeLiquidity(removeParams);
    }

    function testRemoveLiquidity_WithoutSpenderApproval() public {
        // pre-req: alice add liquidity
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);
        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory params;
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        (,,, uint256[] memory liquidityMinted) = binFungiblePositionManager.addLiquidity(params);
        vm.stopPrank();

        assertEq(token0.balanceOf(bob), 0 ether);
        assertEq(token1.balanceOf(bob), 0 ether);

        vm.startPrank(bob);
        removeParams = _getRemoveParams(key1, binIds, liquidityMinted);
        removeParams.from = alice;
        removeParams.to = bob;

        vm.expectRevert(
            abi.encodeWithSelector(IBinFungibleToken.BinFungibleToken_SpenderNotApproved.selector, alice, bob)
        );
        binFungiblePositionManager.removeLiquidity(removeParams);
        vm.stopPrank();

        assertEq(token0.balanceOf(bob), 0 ether);
        assertEq(token1.balanceOf(bob), 0 ether);
    }

    function testRemoveLiquidity_WithSpenderApproval() public {
        // pre-req: alice add liquidity
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);
        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory params;
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        (,,, uint256[] memory liquidityMinted) = binFungiblePositionManager.addLiquidity(params);
        vm.stopPrank();

        assertEq(token0.balanceOf(bob), 0 ether);
        assertEq(token1.balanceOf(bob), 0 ether);

        // Alice granted approval
        vm.prank(alice);
        binFungiblePositionManager.approveForAll(bob, true);

        removeParams = _getRemoveParams(key1, binIds, liquidityMinted);
        removeParams.from = alice;
        removeParams.to = bob;
        vm.prank(bob);
        binFungiblePositionManager.removeLiquidity(removeParams);
        assertEq(token0.balanceOf(bob), 1 ether);
        assertEq(token1.balanceOf(bob), 1 ether);
    }

    function testRemoveLiquidity_MultiplePool() public {
        vm.startPrank(alice);

        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory params;

        // Pre-req: mint key1 and key2
        token0.mint(alice, 3 ether);
        token1.mint(alice, 3 ether);
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        (,,, uint256[] memory liquidityMinted1) = binFungiblePositionManager.addLiquidity(params);
        params = _getAddParams(key2, binIds, 2 ether, 2 ether, activeId, alice);
        (,,, uint256[] memory liquidityMinted2) = binFungiblePositionManager.addLiquidity(params);

        assertEq(token0.balanceOf(alice), 0);
        assertEq(token1.balanceOf(alice), 0);

        removeParams = _getRemoveParams(key1, binIds, liquidityMinted1);
        binFungiblePositionManager.removeLiquidity(removeParams);
        assertEq(token0.balanceOf(alice), 1 ether);
        assertEq(token1.balanceOf(alice), 1 ether);

        removeParams = _getRemoveParams(key2, binIds, liquidityMinted2);
        binFungiblePositionManager.removeLiquidity(removeParams);
        assertEq(token0.balanceOf(alice), 3 ether);
        assertEq(token1.balanceOf(alice), 3 ether);
    }

    function testFuzz_AddRemoveLiquidityMultiple(uint128 amt, uint8 numOfBins) public {
        numOfBins = uint8(bound(numOfBins, 1, 10)); // at least 1 bin
        // at least some amount in each bin and within int128 limits
        amt = uint128(bound(amt, 100, uint128(type(int128).max)));

        amt = amt / 2; // adding liquidity twice, so ensure max amt is divided by 2

        uint24[] memory binIds = getBinIds(activeId, numOfBins);
        uint256[] memory aliceTokenIdMinted;
        uint256[] memory aliceLiquidityMinted;
        uint256[] memory bobTokenIdMinted;
        uint256[] memory bobLiquidityMinted;

        //  Add liquidity
        for (uint256 i; i < 2; i++) {
            address user = i == 0 ? alice : bob;
            token0.mint(user, amt);
            token1.mint(user, amt);
            addParams = _getAddParams(key1, binIds, amt, amt, activeId, user);
            addParams.to = user;

            vm.startPrank(user);
            token0.approve(address(binFungiblePositionManager), amt);
            token1.approve(address(binFungiblePositionManager), amt);
            if (user == alice) {
                (,, aliceTokenIdMinted, aliceLiquidityMinted) = binFungiblePositionManager.addLiquidity(addParams);
            } else {
                (,, bobTokenIdMinted, bobLiquidityMinted) = binFungiblePositionManager.addLiquidity(addParams);
            }
            vm.stopPrank();
        }

        //  Remove liquidity
        for (uint256 i; i < 2; i++) {
            address user = i == 0 ? alice : bob;
            if (user == alice) {
                removeParams = _getRemoveParams(key1, binIds, aliceLiquidityMinted);
                removeParams.from = alice;
            } else {
                removeParams = _getRemoveParams(key1, binIds, bobLiquidityMinted);
                removeParams.from = bob;
            }
            removeParams.to = user;

            vm.startPrank(user);
            binFungiblePositionManager.removeLiquidity(removeParams);

            // verify user balance returned
            assertEq(token0.balanceOf(user), amt);
            assertEq(token1.balanceOf(user), amt);
            vm.stopPrank();
        }
    }

    function _getRemoveParams(PoolKey memory _key, uint24[] memory binIds, uint256[] memory amounts)
        internal
        view
        returns (IBinFungiblePositionManager.RemoveLiquidityParams memory params)
    {
        uint256[] memory ids = new uint256[](binIds.length);
        for (uint256 i; i < binIds.length; i++) {
            ids[i] = uint256(binIds[i]);
        }

        params = IBinFungiblePositionManager.RemoveLiquidityParams({
            poolKey: _key,
            amount0Min: 0,
            amount1Min: 0,
            ids: ids,
            amounts: amounts,
            from: alice,
            to: alice,
            deadline: block.timestamp + 600
        });
    }
}
