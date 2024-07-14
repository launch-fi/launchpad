// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

library ERC721PermitLib {
    error PermitExpired();
    error ApproveToOneself();
    error Unauthorized();
    error InvalidSignature();

    /// @dev Value is equal to keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;

    function DOMAIN_SEPARATOR(bytes32 nameHash, bytes32 versionHash) external view returns (bytes32) {
        return keccak256(
            abi.encode(
                /// @dev keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
                0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f,
                nameHash,
                versionHash,
                block.chainid,
                address(this)
            )
        );
    }

    function permitCheck(
        address spender,
        uint256 tokenId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address owner,
        bytes32 domainSeparatorHash,
        uint256 nonce
    ) external view {
        if (block.timestamp > deadline) {
            revert PermitExpired();
        }

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparatorHash,
                keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, nonce, deadline))
            )
        );
        if (spender == owner) {
            revert ApproveToOneself();
        }

        if (Address.isContract(owner)) {
            /// @dev cast 4 isValidSignature(bytes32,bytes) == 0x1626ba7e
            if (IERC1271(owner).isValidSignature(digest, abi.encodePacked(r, s, v)) == 0x1626ba7e) {
                revert Unauthorized();
            }
        } else {
            address recoveredAddress = ecrecover(digest, v, r, s);
            if (recoveredAddress == address(0)) {
                revert InvalidSignature();
            }
            if (recoveredAddress != owner) {
                revert Unauthorized();
            }
        }
    }
}
