// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import "../../src/interfaces/external/IERC20PermitAllowed.sol";

// has a fake permit that just uses the other signature type for type(uint256).max
contract MockERC20PermitAllowed is MockERC20, IERC20PermitAllowed {
    constructor() MockERC20("MockERC20", "MockERC20", 18) {}

    function permit(
        address holder,
        address spender,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        require(this.nonces(holder) == nonce, "MockERC20PermitAllowed::permit: wrong nonce");
        permit(holder, spender, allowed ? type(uint256).max : 0, expiry, v, r, s);
    }
}
