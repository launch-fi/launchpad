// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ERC721SigUtils} from "../helpers/ERC721SigUtils.sol";
import {MockERC721Permit} from "../helpers/MockERC721Permit.sol";
import {ERC721PermitLib} from "../../src/pool-cl/libraries/ERC721PermitLib.sol";

contract ERC721PermitTest is Test {
    MockERC721Permit ERC721PermitToken;
    ERC721SigUtils sigUtils;

    uint256 alicePrivateKey = 0xA11CE;
    address alice;
    uint256 bobPrivateKey = 0xB0B;
    address bob;
    uint256 carolPrivateKey = 0xC0C;
    address carol;

    function setUp() public {
        ERC721PermitToken = new MockERC721Permit();
        sigUtils = new ERC721SigUtils(ERC721PermitToken.DOMAIN_SEPARATOR());
        alice = vm.addr(alicePrivateKey);
        bob = vm.addr(bobPrivateKey);
        carol = vm.addr(carolPrivateKey);
        ERC721PermitToken.mintTo(alice);
    }

    function testERC721Permit() public {
        vm.startPrank(alice);
        assertEq(ERC721PermitToken.ownerOf(0), alice);

        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(bob, 0, block.timestamp + 60, 0);

        ERC721PermitToken.permit(bob, 0, block.timestamp + 60, v, r, s);
        assertEq(ERC721PermitToken.getApproved(0), bob);

        ERC721PermitToken.transferFrom(alice, carol, 0);
        assertEq(ERC721PermitToken.ownerOf(0), carol);
        assertEq(ERC721PermitToken.tokenNonce(0), 1);
    }

    function testERC721Permit_PermitExpired() public {
        vm.startPrank(alice);
        assertEq(ERC721PermitToken.ownerOf(0), alice);

        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(bob, 0, block.timestamp - 1, 0);

        vm.expectRevert(ERC721PermitLib.PermitExpired.selector);
        ERC721PermitToken.permit(bob, 0, block.timestamp - 1, v, r, s);
    }

    function testERC721Permit_Unauthorized() public {
        vm.startPrank(alice);
        assertEq(ERC721PermitToken.ownerOf(0), alice);

        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(bob, 0, block.timestamp + 60, 0);

        vm.expectRevert(ERC721PermitLib.Unauthorized.selector);
        ERC721PermitToken.permit(carol, 0, block.timestamp + 60, v, r, s);
    }

    function testERC721Permit_ApproveToOneself() public {
        vm.startPrank(alice);
        assertEq(ERC721PermitToken.ownerOf(0), alice);

        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(alice, 0, block.timestamp + 60, 0);

        vm.expectRevert(ERC721PermitLib.ApproveToOneself.selector);
        ERC721PermitToken.permit(alice, 0, block.timestamp + 60, v, r, s);
    }

    function testERC721Permit_InvalidSignature() public {
        vm.startPrank(alice);
        assertEq(ERC721PermitToken.ownerOf(0), alice);

        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(bob, 0, block.timestamp + 60, 1);
        // modify v to simulate invalid signature
        if (v > 1) {
            v = 0;
        } else {
            v = 1;
        }
        vm.expectRevert(ERC721PermitLib.InvalidSignature.selector);
        ERC721PermitToken.permit(bob, 0, block.timestamp + 60, v, r, s);
    }

    /// @dev get a permit signature from alice -> ERC721Permit
    function getPermitSignature(address spender, uint256 tokenId, uint256 deadline, uint256 nonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        // Generate permit signature
        ERC721SigUtils.Permit memory permit =
            ERC721SigUtils.Permit({spender: spender, tokenId: tokenId, nonce: nonce, deadline: deadline});
        bytes32 digest = sigUtils.getTypedDataHash(permit);
        (v, r, s) = vm.sign(alicePrivateKey, digest);
    }
}
