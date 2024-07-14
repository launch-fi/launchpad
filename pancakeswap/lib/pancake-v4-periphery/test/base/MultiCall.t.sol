// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {MockMulticall} from "../helpers/MockMulticall.sol";

import "forge-std/console.sol";

/// @dev Basic test only as the code are taken directly from pancake-v3
contract MulticallTest is Test {
    MockMulticall multicall;
    address alice = makeAddr("alice");

    error CustomError(string);

    function setUp() public {
        multicall = new MockMulticall();
    }

    function testMulticall_RevertMessage() public {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(multicall.functionThatRevertsWithError.selector, "abcdef");

        vm.expectRevert("abcdef");
        multicall.multicall(data);
    }

    function testMulticall_ReturnDataEncoded() public {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(multicall.functionThatReturnsTuple.selector, 1, 2);

        bytes[] memory result = multicall.multicall(data);
        (uint256 a, uint256 b) = abi.decode(result[0], (uint256, uint256));
        assertEq(a, 2);
        assertEq(b, 1);
    }

    function testMulticall_ContextPreserve_MsgValueTwice() public {
        assertEq(multicall.paid(), 0);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(multicall.pays.selector);
        data[1] = abi.encodeWithSelector(multicall.pays.selector);
        multicall.multicall{value: 3}(data);

        assertEq(multicall.paid(), 6);
    }

    function testMulticall_ContextPreserve_MsgSender() public {
        vm.startPrank(alice);
        assertEq(multicall.returnSender(), alice);
    }
}
