// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {BinHelper} from "pancake-v4-core/src/pool-bin/libraries/BinHelper.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolManager} from "pancake-v4-core/src/pool-bin/BinPoolManager.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PackedUint128Math} from "pancake-v4-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {BinFungiblePositionManager} from "../../src/pool-bin/BinFungiblePositionManager.sol";
import {IBinFungiblePositionManager} from "../../src/pool-bin/interfaces/IBinFungiblePositionManager.sol";
import {LiquidityParamsHelper} from "./helpers/LiquidityParamsHelper.sol";
import {BeforeMintSwapHook} from "./helpers/BeforeMintSwapHook.sol";
import {PeripheryValidation} from "../../src/base/PeripheryValidation.sol";
import {BinTokenLibrary} from "../../src/pool-bin/libraries/BinTokenLibrary.sol";

contract BinFungiblePositionManager_AddLiquidityTest is Test, GasSnapshot, LiquidityParamsHelper {
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

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    event TransferBatch(
        address indexed sender, address indexed from, address indexed to, uint256[] ids, uint256[] amounts
    );

    event OnDeposit(PoolId id, address user, uint256[] binIds, uint256[] amounts);
    event OnAfterTokenTransfer(PoolId id, address from, address to, uint256 binId, uint256 amount);

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

        // key1 and key2 with same currency0, currency1 but with different fee
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

        // poolManager.initialize(key1, activeId, ZERO_BYTES);
        binFungiblePositionManager.initialize(key1, activeId, ZERO_BYTES);
        // poolManager.initialize(key2, activeId, ZERO_BYTES);
        binFungiblePositionManager.initialize(key2, activeId, ZERO_BYTES);

        vm.startPrank(alice);
        token0.approve(address(binFungiblePositionManager), 1000 ether);
        token1.approve(address(binFungiblePositionManager), 1000 ether);
        vm.stopPrank();
    }

    function testAddLiquidity_BeforeDeadline() public {
        uint24[] memory binIds = getBinIds(activeId, 3);

        vm.warp(1000); // set block.timestamp
        IBinFungiblePositionManager.AddLiquidityParams memory params =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        params.deadline = 900; // set deadline before block.timestamp

        vm.expectRevert(abi.encodeWithSelector(PeripheryValidation.TransactionTooOld.selector));
        binFungiblePositionManager.addLiquidity(params);
    }

    function testAddLiquidity_IdDesiredOverflow() public {
        uint24[] memory binIds = getBinIds(activeId, 3);

        IBinFungiblePositionManager.AddLiquidityParams memory params =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        params.activeIdDesired = activeId - 1;

        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.IdDesiredOverflows.selector, activeId));
        binFungiblePositionManager.addLiquidity(params);
    }

    function testAddLiquidity_InputActiveIdMismatch(uint256 input) public {
        /// @dev as bin id is max uint24, if val is > uint24.max, it will be invalid
        input = bound(input, uint256(type(uint24).max) + 1, type(uint256).max);

        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory params;

        // active id above type(uint24).max
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        params.activeIdDesired = input;
        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.AddLiquidityInputActiveIdMismath.selector));
        binFungiblePositionManager.addLiquidity(params);

        // active id normal, but slippage above type(uint24).max
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        params.idSlippage = input;
        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.AddLiquidityInputActiveIdMismath.selector));
        binFungiblePositionManager.addLiquidity(params);
    }

    function testAddLiquidity_InputLengthMisMatch() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory params;

        // distributionX mismatch
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        params.distributionX = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.InputLengthMismatch.selector));
        binFungiblePositionManager.addLiquidity(params);

        // distributionY mismatch
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        params.distributionY = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.InputLengthMismatch.selector));
        binFungiblePositionManager.addLiquidity(params);

        // deltaIds mismatch
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        params.deltaIds = new int256[](0);
        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.InputLengthMismatch.selector));
        binFungiblePositionManager.addLiquidity(params);
    }

    function testAddLiquidity_AddLiquiditySlippage() public {
        // mint alice required token
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);

        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory params;

        // overwrite amount0Min
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        params.amount0Min = 1.1 ether;
        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.OutputAmountSlippage.selector));
        binFungiblePositionManager.addLiquidity(params);

        // overwrite amount1Min
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        params.amount1Min = 1.1 ether;
        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.OutputAmountSlippage.selector));
        binFungiblePositionManager.addLiquidity(params);

        // overwrite to 1 eth (expected to not fail)
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        params.amount0Min = 1 ether;
        params.amount1Min = 1 ether;
        binFungiblePositionManager.addLiquidity(params);
    }

    function testAddLiquidity_MintToBob() public {
        // mint alice required token
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);

        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory params;
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);

        // overwrite NFT receiver to bob
        params.to = bob;

        // add liquidity
        (,,, uint256[] memory _liquidityMinted) = binFungiblePositionManager.addLiquidity(params);

        for (uint256 i; i < binIds.length; i++) {
            // verify nft minted to bob
            uint256 tokenId = key1.toId().toTokenId(binIds[i]); // key1.toBinToken(binIds[i]);
            uint256 balance = binFungiblePositionManager.balanceOf(bob, tokenId);
            assertEq(balance, _liquidityMinted[i]);
            assertGt(balance, 0);

            // verify no nft minted to alice
            uint256 aliceBal = binFungiblePositionManager.balanceOf(alice, tokenId);
            assertEq(aliceBal, 0);
        }
    }

    function testAddLiquidity_MultiplePool() public {
        // mint alice required token
        token0.mint(alice, 2 ether);
        token1.mint(alice, 2 ether);

        vm.startPrank(alice);

        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory params;

        // mint key1 and key2
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        (,,, uint256[] memory _liquidityMinted1) = binFungiblePositionManager.addLiquidity(params);

        params = _getAddParams(key2, binIds, 1 ether, 1 ether, activeId, alice);
        (,,, uint256[] memory _liquidityMinted2) = binFungiblePositionManager.addLiquidity(params);

        for (uint256 i; i < binIds.length; i++) {
            uint256 balance1 = binFungiblePositionManager.balanceOf(alice, key1.toId().toTokenId(binIds[i])); // key1.toBinToken(binIds[i]));
            assertEq(balance1, _liquidityMinted1[i]);

            uint256 balance2 = binFungiblePositionManager.balanceOf(alice, key2.toId().toTokenId(binIds[i])); // key2.toBinToken(binIds[i]));
            assertEq(balance2, _liquidityMinted2[i]);
        }
    }

    function testPositions_InvalidTokenId(uint256 tokenId) public {
        vm.expectRevert(abi.encodeWithSelector(IBinFungiblePositionManager.InvalidTokenID.selector));
        binFungiblePositionManager.positions(tokenId);
    }

    function testPositions() public {
        // pre-test, verify alice has 1e18 token0 and token1
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);
        assertEq(token0.balanceOf(alice), 1 ether);
        assertEq(token1.balanceOf(alice), 1 ether);

        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory params;
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        (,, uint256[] memory tokenIds,) = binFungiblePositionManager.addLiquidity(params);

        for (uint256 i; i < tokenIds.length; i++) {
            (Currency curr0, Currency curr1, uint24 fee, uint24 binId) =
                binFungiblePositionManager.positions(tokenIds[i]);
            assertEq(Currency.unwrap(curr0), Currency.unwrap(key1.currency0));
            assertEq(Currency.unwrap(curr1), Currency.unwrap(key1.currency1));
            assertEq(fee, key1.fee);
            assertEq(binId, binIds[i]);
        }
    }

    function testAddLiquidityWithActiveId() public {
        // pre-test, verify alice has 1e18 token0 and token1
        token0.mint(alice, 1 ether);
        token1.mint(alice, 1 ether);
        assertEq(token0.balanceOf(alice), 1 ether);
        assertEq(token1.balanceOf(alice), 1 ether);

        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory params;
        params = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);

        // Expect emitted events
        uint256[] memory liquidityMinted = new uint256[](binIds.length);
        bytes32 binReserves = PackedUint128Math.encode(0, 0); // binReserve=0 for new pool
        liquidityMinted[0] = calculateLiquidityMinted(binReserves, 0 ether, 0.5 ether, binIds[0], 10, 0);
        liquidityMinted[1] = calculateLiquidityMinted(binReserves, 0.5 ether, 0.5 ether, binIds[1], 10, 0);
        liquidityMinted[2] = calculateLiquidityMinted(binReserves, 0.5 ether, 0 ether, binIds[2], 10, 0);
        uint256[] memory tokenIds = new uint256[](binIds.length);
        for (uint256 i; i < binIds.length; i++) {
            tokenIds[i] = key1.toId().toTokenId(binIds[i]);
        }
        vm.expectEmit();
        emit TransferBatch(alice, address(0), alice, tokenIds, liquidityMinted);

        // amt0, amt1 = total amt0/amt1 from addLiquidity -- 660207 -
        snapStart("BinFungiblePositionManager_AddLiquidityTest#testAddLiquidityWithActiveId");
        (uint128 amt0, uint128 amt1, uint256[] memory _tokenIds, uint256[] memory _liquidityMinted) =
            binFungiblePositionManager.addLiquidity(params);
        snapEnd();

        // verify token taken from alice
        assertEq(amt0, 1 ether);
        assertEq(amt1, 1 ether);
        assertEq(token0.balanceOf(alice), 0);
        assertEq(token1.balanceOf(alice), 0);

        for (uint256 i; i < binIds.length; i++) {
            // verify nft minted to user
            uint256 balance = binFungiblePositionManager.balanceOf(alice, tokenIds[i]);
            assertEq(balance, _liquidityMinted[i]);
            assertGt(balance, 0);

            // verify return value from addLiquidity
            assertEq(tokenIds[i], _tokenIds[i]);
        }
    }

    function testAddLiquidityOutsideActiveId() public {
        // add at the left side, so all tokenY
        token1.mint(alice, 2 ether);

        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId - 10, 2); // all binId to the left

        IBinFungiblePositionManager.AddLiquidityParams memory params;
        params = _getAddParams(key1, binIds, 0, 1 ether, activeId, alice);

        snapStart("BinFungiblePositionManager_AddLiquidityTest#testAddLiquidityOutsideActiveId_NewId");
        (uint128 amt0, uint128 amt1,, uint256[] memory _liquidityMinted) =
            binFungiblePositionManager.addLiquidity(params);
        snapEnd();

        // verify token taken from alice
        assertEq(amt0, 0 ether);
        assertEq(amt1, 1 ether);
        assertEq(token1.balanceOf(alice), 1 ether);

        // verify nft minted
        for (uint256 i; i < binIds.length; i++) {
            // verify nft minted to user with shares > 0
            uint256 tokenId = key1.toId().toTokenId(binIds[i]);
            uint256 balance = binFungiblePositionManager.balanceOf(alice, tokenId);
            assertEq(balance, _liquidityMinted[i]);
            assertGt(balance, 0);
        }

        // re-add existing id, gas should be way cheaper as no ssload
        snapStart("BinFungiblePositionManager_AddLiquidityTest#testAddLiquidityOutsideActiveId_ExistingId");
        binFungiblePositionManager.addLiquidity(params);
        snapEnd();
    }

    function testAddLiquidityWithActiveId_WithHook() public {
        // pre-test, mint alice 4 ether of token0 and token1
        token0.mint(alice, 4 ether);
        token1.mint(alice, 4 ether);

        // step 1: setup pool with hook
        BeforeMintSwapHook hook = new BeforeMintSwapHook(IBinPoolManager(address(poolManager)), IVault(address(vault)));
        hook.setHooksRegistrationBitmap(0x0004); //  0000 0000 0000 0010 -- beforeMint
        token0.mint(address(hook), 1 ether); // so the hook have token to swap in the before()

        key1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(hook)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: bytes32(uint256(0x0004)).setBinStep(10)
        });
        poolManager.initialize(key1, activeId, ZERO_BYTES);

        // step 2: Prep params of adding 2 eth of amt0/amt1 5 bins around activeId
        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 5); // 5 bins in total
        IBinFungiblePositionManager.AddLiquidityParams memory params =
            _getAddParams(key1, binIds, 2 ether, 2 ether, activeId, alice);

        // Step 3: add initial liquidity -- beofreMint() wont swap due to pool having 0 liquidity
        snapStart("BinFungiblePositionManager_AddLiquidityTest#testAddLiquidityWithActiveId_WithHook");
        binFungiblePositionManager.addLiquidity(params);
        snapEnd();

        // Step 4: add more liquidity - beforeMint() will swap as pool has sufficient liquidity now
        // verify error happens if activeId changes and user happen to add to activeId
        vm.expectRevert(abi.encodeWithSelector(BinHelper.BinHelper__CompositionFactorFlawed.selector, 2 ** 23));
        binFungiblePositionManager.addLiquidity(params);
    }

    /// @dev User adding liquidity in this scenario should not produce error
    /// 1. user add liquidity at [activeId-10, activeId-9]
    /// 2. hook.beforeMint() change activeId to activeId-2
    /// 3. user liquidity added at [activeId-10, activeId-9] successfully
    /// Context: no impact to user even if activeId changes in beforeMint() as bin pricing are the same
    function testAddLiquidityOutsideActiveId_WithHook() public {
        // pre-test, mint alice 4 ether of token0 and token1
        token0.mint(alice, 4 ether);
        token1.mint(alice, 4 ether);

        // step 1: setup pool with hook
        BeforeMintSwapHook hook = new BeforeMintSwapHook(IBinPoolManager(address(poolManager)), IVault(address(vault)));
        hook.setHooksRegistrationBitmap(0x0004); //  0000 0000 0000 0010 -- beforeMint
        token0.mint(address(hook), 1 ether); // so the hook have token to swap in the before()

        key1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(hook)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: bytes32(uint256(0x0004)).setBinStep(10)
        });
        poolManager.initialize(key1, activeId, ZERO_BYTES);

        // step 2: Prep params of adding 2 eth of amt0/amt1 5 bins at active id range
        vm.startPrank(alice);
        uint24[] memory binIds = getBinIds(activeId, 5); // 5 bins in total
        IBinFungiblePositionManager.AddLiquidityParams memory params =
            _getAddParams(key1, binIds, 2 ether, 2 ether, activeId, alice);

        // Step 3: add initial liquidity -- beforeMint() wont swap due to pool having 0 liquidity
        binFungiblePositionManager.addLiquidity(params);
        assertApproxEqAbs(token0.balanceOf(alice), 2 ether, 10); // left with 2 eth on amt0
        assertApproxEqAbs(token1.balanceOf(alice), 2 ether, 10); // left with 2 eth on amt1

        // Step 4: add more liquidity - beforeMint() will swap as pool has sufficient liquidity now
        binIds = getBinIds(activeId - 100, 5); // 5 bins in total
        params = _getAddParams(key1, binIds, 0 ether, 2 ether, activeId, alice);

        // mint, verify no error and token taken from user
        binFungiblePositionManager.addLiquidity(params);
        assertApproxEqAbs(token0.balanceOf(alice), 2 ether, 10); // amt0 remain the same
        assertApproxEqAbs(token1.balanceOf(alice), 0 ether, 10); // amt1 taken from step 4
    }

    function testFuzz_AddLiquidityMultiple(uint128 amt, uint8 numOfBins) public {
        numOfBins = uint8(bound(numOfBins, 1, 10)); // at least 1 bin
        // at least some amount in each bin and within int128 limits
        amt = uint128(bound(amt, 100, uint128(type(int128).max)));

        amt = amt / 2; // adding liquidity twice, so ensure max amt is divided by 2

        IBinFungiblePositionManager.AddLiquidityParams memory addParams;

        uint24[] memory binIds = getBinIds(activeId, numOfBins);
        uint256[] memory aliceTokenIds;
        uint256[] memory aliceLiquidityMinted;
        uint256[] memory bobTokenIds;
        uint256[] memory bobLiquidityMinted;

        for (uint256 i; i < 2; i++) {
            address user = i == 0 ? alice : bob;

            token0.mint(user, amt);
            token1.mint(user, amt);
            vm.startPrank(user);
            token0.approve(address(binFungiblePositionManager), amt);
            token1.approve(address(binFungiblePositionManager), amt);

            //  Add liquidity,
            addParams = _getAddParams(key1, binIds, amt, amt, activeId, user);
            addParams.to = user;

            if (user == alice) {
                (,, aliceTokenIds, aliceLiquidityMinted) = binFungiblePositionManager.addLiquidity(addParams);
            } else {
                (,, bobTokenIds, bobLiquidityMinted) = binFungiblePositionManager.addLiquidity(addParams);
            }

            for (uint256 j; j < binIds.length; j++) {
                // verify nft minted to user
                uint256 tokenId = key1.toId().toTokenId(binIds[j]); // key1.toBinToken(binIds[i]);
                uint256 balance = binFungiblePositionManager.balanceOf(user, tokenId);

                if (user == alice) {
                    assertEq(balance, aliceLiquidityMinted[j]);
                    assertEq(tokenId, aliceTokenIds[j]);
                } else {
                    assertEq(balance, bobLiquidityMinted[j]);
                    assertEq(tokenId, bobTokenIds[j]);
                }
                assertGt(balance, 0);
            }
            vm.stopPrank();
        }

        for (uint256 i; i < binIds.length; i++) {
            assertEq(aliceTokenIds[i], bobTokenIds[i]);
            assertEq(aliceLiquidityMinted[i], bobLiquidityMinted[i]);
        }
    }

    function _getAddParams(
        PoolKey memory _key,
        uint24[] memory binIds,
        uint128 amountX,
        uint128 amountY,
        uint24 activeIdDesired
    ) internal view returns (IBinFungiblePositionManager.AddLiquidityParams memory params) {
        uint256 totalBins = binIds.length;

        uint8 nbBinX; // num of bins to the right
        uint8 nbBinY; // num of bins to the left
        for (uint256 i; i < totalBins; ++i) {
            if (binIds[i] >= activeId) nbBinX++;
            if (binIds[i] <= activeId) nbBinY++;
        }

        uint256[] memory distribX = new uint256[](totalBins);
        uint256[] memory distribY = new uint256[](totalBins);
        for (uint256 i; i < totalBins; ++i) {
            uint24 binId = binIds[i];
            distribX[i] = binId >= activeId && nbBinX > 0 ? uint256(1e18 / nbBinX).safe64() : 0;
            distribY[i] = binId <= activeId && nbBinY > 0 ? uint256(1e18 / nbBinY).safe64() : 0;
        }

        params = IBinFungiblePositionManager.AddLiquidityParams({
            poolKey: _key,
            amount0: amountX,
            amount1: amountY,
            amount0Min: 0,
            amount1Min: 0,
            activeIdDesired: uint256(activeIdDesired),
            idSlippage: 0,
            deltaIds: convertToRelative(binIds, activeId),
            distributionX: distribX,
            distributionY: distribY,
            to: alice,
            deadline: block.timestamp + 600
        });
    }
}
