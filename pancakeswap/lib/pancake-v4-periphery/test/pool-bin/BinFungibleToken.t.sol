// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {MockBinFungibleToken} from "./helpers/MockBinFungibleToken.sol";
import {IBinFungibleToken} from "../../src/pool-bin/interfaces/IBinFungibleToken.sol";

contract BinFungibleTokenTest is Test, GasSnapshot {
    MockBinFungibleToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event TransferBatch(
        address indexed sender, address indexed from, address indexed to, uint256[] ids, uint256[] amounts
    );

    event ApprovalForAll(address indexed account, address indexed sender, bool approved);

    function setUp() public {
        token = new MockBinFungibleToken();
    }

    function testName() public {
        assertEq(token.name(), "Bin Fungible Token");
    }

    function testSymbol() public {
        assertEq(token.symbol(), "BFT");
    }

    function testMint(uint256 id, uint256 amt) public {
        // before bal
        assertEq(token.balanceOf(alice, id), 0);

        // mint and verify bal
        snapStart("BinFungibleTokenTest#testMint");
        token.mint(alice, id, amt);
        snapEnd();
        assertEq(token.balanceOf(alice, id), amt);
    }

    function testMintMultiple(uint256 id, uint256 amt) public {
        amt = amt / 2;

        // before bal
        assertEq(token.balanceOf(alice, id), 0);
        assertEq(token.balanceOf(bob, id), 0);

        // mint and verify bal
        token.mint(alice, id, amt);
        assertEq(token.balanceOf(alice, id), amt);
        token.mint(bob, id, amt);
        assertEq(token.balanceOf(bob, id), amt);
    }

    function testBurn(uint256 id, uint256 amt) public {
        // before: mint and verify bal
        token.mint(alice, id, amt);
        assertEq(token.balanceOf(alice, id), amt);

        // burn and verify bal
        snapStart("BinFungibleTokenTest#testBurn");
        token.burn(alice, id, amt);
        snapEnd();
        assertEq(token.balanceOf(alice, id), 0);
    }

    function testBurn_ExceedBalance(uint256 id, uint256 amt) public {
        // -1 as we will +1 in the burn
        vm.assume(amt < type(uint256).max - 1);

        // before: mint and verify bal
        token.mint(alice, id, amt);
        assertEq(token.balanceOf(alice, id), amt);

        vm.expectRevert(
            abi.encodeWithSelector(IBinFungibleToken.BinFungibleToken_BurnExceedsBalance.selector, alice, id, amt + 1)
        );
        token.burn(alice, id, amt + 1);
    }

    function testBalanceOfBatch() public {
        address[] memory owner = new address[](2);
        owner[0] = alice;
        owner[1] = bob;

        uint256[] memory ids = new uint256[](2);
        ids[0] = 10;
        ids[1] = 11;

        // verify 0 bal
        uint256[] memory beforeBal = token.balanceOfBatch(owner, ids);
        for (uint256 i; i < beforeBal.length; i++) {
            assertEq(beforeBal[i], 0);
        }

        // mint
        uint256[] memory mintAmt = new uint256[](2);
        mintAmt[0] = 100;
        mintAmt[1] = 1000;
        token.mint(owner[0], ids[0], mintAmt[0]);
        token.mint(owner[1], ids[1], mintAmt[1]);

        // verify bal
        uint256[] memory afterBal = token.balanceOfBatch(owner, ids);
        for (uint256 i; i < afterBal.length; i++) {
            assertEq(afterBal[i], mintAmt[i]);
        }
    }

    function testBalanceOfBatch_InvalidLength() public {
        address[] memory owner = new address[](2);
        owner[0] = alice;
        owner[1] = bob;

        uint256[] memory ids = new uint256[](1);
        ids[0] = 10;

        vm.expectRevert(abi.encodeWithSelector(IBinFungibleToken.BinFungibleToken_InvalidLength.selector));
        token.balanceOfBatch(owner, ids);
    }

    function testApproveForAll_SelfApproval() public {
        assertEq(token.isApprovedForAll(alice, bob), false);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IBinFungibleToken.BinFungibleToken_SelfApproval.selector, alice));
        token.approveForAll(alice, true);
    }

    function testApproveForAll() public {
        assertEq(token.isApprovedForAll(alice, bob), false);

        vm.startPrank(alice);

        // approve from false -> true
        vm.expectEmit();
        emit ApprovalForAll(alice, bob, true);
        token.approveForAll(bob, true);
        assertEq(token.isApprovedForAll(alice, bob), true);

        // approve from true -> false
        vm.expectEmit();
        emit ApprovalForAll(alice, bob, false);
        token.approveForAll(bob, false);
        assertEq(token.isApprovedForAll(alice, bob), false);
    }

    function testBatchTransferFrom_InvalidLength() public {
        vm.startPrank(alice);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 10;
        uint256[] memory amounts = new uint256[](0);

        vm.expectRevert(abi.encodeWithSelector(IBinFungibleToken.BinFungibleToken_InvalidLength.selector));
        token.batchTransferFrom(alice, bob, ids, amounts);
    }

    function testBatchTransferFrom_AddressThisOrZero(uint256 id, uint256 amt) public {
        vm.startPrank(alice);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amt;

        // transfer
        vm.expectRevert(abi.encodeWithSelector(IBinFungibleToken.BinFungibleToken_AddressThisOrZero.selector));
        token.batchTransferFrom(alice, address(0), ids, amounts);

        vm.expectRevert(abi.encodeWithSelector(IBinFungibleToken.BinFungibleToken_AddressThisOrZero.selector));
        token.batchTransferFrom(alice, address(token), ids, amounts);
    }

    function testBatchTransferFrom_NotApproved(uint256 id, uint256 amt) public {
        vm.startPrank(alice);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amt;

        vm.expectRevert(
            abi.encodeWithSelector(IBinFungibleToken.BinFungibleToken_SpenderNotApproved.selector, bob, alice)
        );
        token.batchTransferFrom(bob, alice, ids, amounts);
    }

    function testBatchTransferFromExceedBalance(uint256 id, uint256 amt) public {
        vm.assume(amt > 0);
        amt = amt - 1; // as we will add +1 in transfer later

        // pre-req mint some nft to alice
        token.mint(alice, id, amt);
        assertEq(token.balanceOf(alice, id), amt);

        vm.startPrank(alice);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amt + 1;

        // transfer
        vm.expectRevert(
            abi.encodeWithSelector(
                IBinFungibleToken.BinFungibleToken_TransferExceedsBalance.selector, alice, ids[0], amounts[0]
            )
        );
        token.batchTransferFrom(alice, bob, ids, amounts);
    }

    function testBatchTransferFrom_FromOwner(uint256 id, uint256 amt) public {
        // pre-req mint some nft to alice
        token.mint(alice, id, amt);
        assertEq(token.balanceOf(alice, id), amt);

        vm.startPrank(alice);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amt;

        // transfer
        vm.expectEmit();
        emit TransferBatch(alice, alice, bob, ids, amounts);
        snapStart("BinFungibleTokenTest#testBatchTransferFrom_FromOwner");
        token.batchTransferFrom(alice, bob, ids, amounts);
        snapEnd();

        // verify
        assertEq(token.balanceOf(alice, id), 0);
        assertEq(token.balanceOf(bob, id), amt);
    }

    function testBatchTransferFrom_FromBob(uint256 id, uint256 amt) public {
        // pre-req mint some nft to alice
        token.mint(alice, id, amt);
        assertEq(token.balanceOf(alice, id), amt);

        // alice give bob approval
        vm.prank(alice);
        token.approveForAll(bob, true);

        // bob tries to transfer
        vm.startPrank(bob);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amt;

        // transfer
        vm.expectEmit();
        emit TransferBatch(bob, alice, bob, ids, amounts);
        snapStart("BinFungibleTokenTest#testBatchTransferFrom_FromBob");
        token.batchTransferFrom(alice, bob, ids, amounts);
        snapEnd();

        // verify
        assertEq(token.balanceOf(alice, id), 0);
        assertEq(token.balanceOf(bob, id), amt);
    }
}
