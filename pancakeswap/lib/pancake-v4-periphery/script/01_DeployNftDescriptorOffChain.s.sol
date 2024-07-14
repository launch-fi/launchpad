// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {NonfungibleTokenPositionDescriptorOffChain} from "../src/pool-cl/NonfungibleTokenPositionDescriptorOffChain.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * forge script script/01_DeployNftDescriptorOffChain.s.sol:DeployNftDescriptorOffChainScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployNftDescriptorOffChainScript is BaseScript {
    using Strings for uint256;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        NonfungibleTokenPositionDescriptorOffChain NFTPositionDescriptorContract =
            new NonfungibleTokenPositionDescriptorOffChain();
        ProxyAdmin proxyAdminContract = new ProxyAdmin();
        emit log_named_address("NFTPositionDescriptorProxyAdmin", address(proxyAdminContract));

        string memory baseTokenURI = string.concat("https://nft.pancakeswap.com/v4/", block.chainid.toString(), "/");
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(NFTPositionDescriptorContract),
            address(proxyAdminContract),
            abi.encodeCall(NonfungibleTokenPositionDescriptorOffChain.initialize, (baseTokenURI))
        );

        // save the proxy address to the config, not the implementation address
        emit log_named_address("nonFungibleTokenPositionDescriptorOffChain", address(proxy));

        vm.stopBroadcast();
    }
}

/**
 * forge script script/01_DeployNftDescriptorOffChain.s.sol:UpgradeNftDescriptorOffChainScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract UpgradeNftDescriptorOffChainScript is BaseScript {
    using Strings for uint256;

    function run() public {
        // Please use the ProxyAdmin owner's key to run this script
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        NonfungibleTokenPositionDescriptorOffChain newNFTPositionDescriptorContract =
            new NonfungibleTokenPositionDescriptorOffChain();

        address NFTPositionDescriptorProxy = getAddressFromConfig("nonFungibleTokenPositionDescriptorOffChain");
        address NFTPositionDescriptorProxyAdmin = getAddressFromConfig("NFTPositionDescriptorProxyAdmin");

        ProxyAdmin(NFTPositionDescriptorProxyAdmin).upgrade(
            ITransparentUpgradeableProxy(NFTPositionDescriptorProxy), address(newNFTPositionDescriptorContract)
        );

        vm.stopBroadcast();
    }
}
