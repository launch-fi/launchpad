// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BinFungibleToken} from "../../../src/pool-bin/BinFungibleToken.sol";

contract MockBinFungibleToken is BinFungibleToken {
    function mint(address to, uint256 id, uint256 amount) public {
        _mint(to, id, amount);
    }

    function burn(address from, uint256 id, uint256 amount) public {
        _burn(from, id, amount);
    }
}
