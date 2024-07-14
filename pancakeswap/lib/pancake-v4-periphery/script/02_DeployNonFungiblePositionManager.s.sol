// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {NonfungiblePositionManager} from "../src/pool-cl/NonfungiblePositionManager.sol";

/**
 * forge script script/02_DeployNonFungiblePositionManager.s.sol:DeployNonFungiblePositionManagerScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployNonFungiblePositionManagerScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address vault = getAddressFromConfig("vault");
        emit log_named_address("Vault", vault);

        address clPoolManager = getAddressFromConfig("clPoolManager");
        emit log_named_address("CLPoolManager", clPoolManager);

        address tokenDescriptor = getAddressFromConfig("nonFungibleTokenPositionDescriptorOffChain");
        emit log_named_address("NonFungibleTokenPositionDescriptorOffChain", tokenDescriptor);

        address weth = getAddressFromConfig("weth");
        emit log_named_address("WETH", weth);

        NonfungiblePositionManager nonFungiblePositionManager =
            new NonfungiblePositionManager(IVault(vault), ICLPoolManager(clPoolManager), tokenDescriptor, weth);
        emit log_named_address("NonFungiblePositionManager", address(nonFungiblePositionManager));

        vm.stopBroadcast();
    }
}
