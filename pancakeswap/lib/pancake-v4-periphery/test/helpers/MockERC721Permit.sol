// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC721Permit} from "../../src/pool-cl/base/ERC721Permit.sol";

contract MockERC721Permit is ERC721Permit {
    uint256 public tokenId;
    mapping(uint256 => uint256) public tokenNonce;

    constructor() ERC721Permit("Pancake V4 Positions NFT-V1", "PCS-V4-POS", "1") {}

    function mint() external {
        _mint(msg.sender, tokenId++);
    }

    function mintTo(address to) external {
        _mint(to, tokenId++);
    }

    function _getAndIncrementNonce(uint256 _tokenId) internal override returns (uint256) {
        return tokenNonce[_tokenId]++;
    }
}
