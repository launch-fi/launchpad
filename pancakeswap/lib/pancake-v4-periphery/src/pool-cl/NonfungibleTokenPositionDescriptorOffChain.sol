// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import "./interfaces/INonfungibleTokenPositionDescriptor.sol";

/// @title Describes NFT token positions
contract NonfungibleTokenPositionDescriptorOffChain is INonfungibleTokenPositionDescriptor {
    using Strings for uint256;

    string private _baseTokenURI;

    function initialize(string calldata baseTokenURI) external {
        _baseTokenURI = baseTokenURI;
    }

    /// @inheritdoc INonfungibleTokenPositionDescriptor
    function tokenURI(INonfungiblePositionManager positionManager, uint256 tokenId)
        external
        view
        override
        returns (string memory)
    {
        return bytes(_baseTokenURI).length > 0 ? string.concat(_baseTokenURI, tokenId.toString()) : "";
    }
}
