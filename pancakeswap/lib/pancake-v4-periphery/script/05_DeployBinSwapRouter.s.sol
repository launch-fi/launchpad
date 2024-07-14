// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinSwapRouter} from "../src/pool-bin/BinSwapRouter.sol";

/**
 * forge script script/05_DeployBinSwapRouter.s.sol:DeployBinSwapRouterScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployBinSwapRouterScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address vault = getAddressFromConfig("vault");
        emit log_named_address("Vault", vault);

        address binPoolManager = getAddressFromConfig("binPoolManager");
        emit log_named_address("BinPoolManager", binPoolManager);

        address weth = getAddressFromConfig("weth");
        emit log_named_address("WETH", weth);

        BinSwapRouter binSwapRouter = new BinSwapRouter(IVault(vault), IBinPoolManager(binPoolManager), weth);
        emit log_named_address("BinSwapRouter", address(binSwapRouter));

        vm.stopBroadcast();
    }
}
