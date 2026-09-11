// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AtomaVault.sol";

contract UpgradeV4 is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address proxy = vm.envAddress("PROXY_ADDRESS");

        vm.startBroadcast(deployerPk);
        AtomaVault impl = new AtomaVault();
        vm.stopBroadcast();

        bytes memory upgradeCalldata = abi.encodeCall(
            UUPSUpgradeable.upgradeToAndCall,
            (address(impl), "")
        );

        console.log("=== Upgrade payload - submit via Gnosis Safe ===");
        console.log("Proxy address (the 'To' field in Safe):");
        console.logAddress(proxy);
        console.log("");
        console.log("New implementation:");
        console.logAddress(address(impl));
        console.log("");
        console.log("Calldata (paste into Safe 'Data (Hex encoded)' field):");
        console.logBytes(upgradeCalldata);
        console.log("");
        console.log("After Safe execution, verify on Arbiscan:");
        console.log("forge verify-contract <impl> src/AtomaVault.sol:AtomaVault --chain arbitrum --etherscan-api-key $ARBISCAN_API_KEY --watch");
    }
}
