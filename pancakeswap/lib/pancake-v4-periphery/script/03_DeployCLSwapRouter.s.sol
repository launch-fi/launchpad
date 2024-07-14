// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLSwapRouter} from "../src/pool-cl/CLSwapRouter.sol";

/**
 * forge script script/03_DeployCLSwapRouter.s.sol:DeployCLSwapRouterScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployCLSwapRouterScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address vault = getAddressFromConfig("vault");
        emit log_named_address("Vault", vault);

        address clPoolManager = getAddressFromConfig("clPoolManager");
        emit log_named_address("CLPoolManager", clPoolManager);

        address weth = getAddressFromConfig("weth");
        emit log_named_address("WETH", weth);

        CLSwapRouter clSwapRouter = new CLSwapRouter(IVault(vault), ICLPoolManager(clPoolManager), weth);
        emit log_named_address("CLSwapRouter", address(clSwapRouter));

        vm.stopBroadcast();
    }
}
