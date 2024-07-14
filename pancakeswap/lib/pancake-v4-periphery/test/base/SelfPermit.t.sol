// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {SigUtils} from "../helpers/SigUtils.sol";
import {MockSelfPermit} from "../helpers/MockSelfPermit.sol";
import {MockERC20PermitAllowed} from "../helpers/MockERC20PermitAllowed.sol";

/// @dev Basic test only as the code are taken directly from pancake-v3
contract SelfPermitTest is Test {
    MockSelfPermit selfPermit;
    MockERC20PermitAllowed token;
    SigUtils sigUtils;

    uint256 alicePrivateKey = 0xA11CE;
    address alice;

    function setUp() public {
        selfPermit = new MockSelfPermit();
        token = new MockERC20PermitAllowed();
        sigUtils = new SigUtils(token.DOMAIN_SEPARATOR());

        alice = vm.addr(alicePrivateKey);
    }

    function testSelfPermit() public {
        vm.startPrank(alice);
        assertEq(token.allowance(alice, address(selfPermit)), 0);

        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(1 ether, block.timestamp + 60, 0);

        selfPermit.selfPermit(address(token), 1 ether, block.timestamp + 60, v, r, s);
        assertEq(token.allowance(alice, address(selfPermit)), 1 ether);
    }

    function testSelfPermitIfNecessary_AlreadyPermitted() public {
        vm.startPrank(alice);

        // Enable 1 ether allowance and verify allowance 1 ether
        (uint8 v, bytes32 r, bytes32 s) = getPermitSignature(1 ether, block.timestamp + 60, 0);
        selfPermit.selfPermit(address(token), 1 ether, block.timestamp + 60, v, r, s);
        assertEq(token.allowance(alice, address(selfPermit)), 1 ether);

        // Try enabling 0.5 ether and verify allowance still 1 ether
        (v, r, s) = getPermitSignature(0.5 ether, block.timestamp + 60, 1);
        selfPermit.selfPermitIfNecessary(address(token), 0.5 ether, block.timestamp + 60, v, r, s);
        assertEq(token.allowance(alice, address(selfPermit)), 1 ether);

        // // Try enabling 2 ether and verify allowance now 2 ether
        (v, r, s) = getPermitSignature(2 ether, block.timestamp + 60, 1);
        selfPermit.selfPermitIfNecessary(address(token), 2 ether, block.timestamp + 60, v, r, s);
        assertEq(token.allowance(alice, address(selfPermit)), 2 ether);
    }

    function testSelfPermitAllowed() public {
        vm.startPrank(alice);
        assertEq(token.allowance(alice, address(selfPermit)), 0);

        (uint8 v, bytes32 r, bytes32 s) = getPermitAllowedSignature(0, block.timestamp + 60);

        selfPermit.selfPermitAllowed(address(token), 0, block.timestamp + 60, v, r, s);
        assertEq(token.allowance(alice, address(selfPermit)), type(uint256).max);
    }

    function testSelfPermitAllowedIfNecessary_AlreadyPermitted() public {
        // Enable 1 ether allowance
        vm.startPrank(alice);
        (uint8 v, bytes32 r, bytes32 s) = getPermitAllowedSignature(0, block.timestamp + 60);
        selfPermit.selfPermitAllowed(address(token), 0, block.timestamp + 60, v, r, s);
        assertEq(token.allowance(alice, address(selfPermit)), type(uint256).max);

        // Try enabling permit again
        (v, r, s) = getPermitAllowedSignature(1, block.timestamp + 60);
        selfPermit.selfPermitAllowed(address(token), 1, block.timestamp + 60, v, r, s);

        // Verify allowance still same (always uint256.max)
        assertEq(token.allowance(alice, address(selfPermit)), type(uint256).max);
    }

    /// @dev get a permit signature from alice -> selfPermit
    function getPermitSignature(uint256 value, uint256 deadline, uint256 nonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        // Generate permit signature
        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: alice,
            spender: address(selfPermit),
            value: value,
            nonce: nonce,
            deadline: deadline
        });
        bytes32 digest = sigUtils.getTypedDataHash(permit);
        (v, r, s) = vm.sign(alicePrivateKey, digest);
    }

    /// @dev get a permitAllowed signature from alice -> selfPermit
    function getPermitAllowedSignature(uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        // Generate permit signature
        SigUtils.Permit memory permit = SigUtils.Permit({
            owner: alice,
            spender: address(selfPermit),
            value: type(uint256).max, // selfPermitAllowed is always max value
            nonce: nonce,
            deadline: deadline
        });
        bytes32 digest = sigUtils.getTypedDataHash(permit);
        (v, r, s) = vm.sign(alicePrivateKey, digest);
    }
}
