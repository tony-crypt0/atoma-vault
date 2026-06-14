// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/AtomaVault.sol";

contract UpgradeV2 is Script {
    address constant PROXY = 0xCC56410e1a136aF0eCEb7241c6aE394F4d8b581c;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPk);
        AtomaVault impl = new AtomaVault();
        vm.stopBroadcast();

        bytes memory innerCalldata = abi.encodeCall(AtomaVault.initializeV2, ());
        bytes memory upgradeCalldata = abi.encodeCall(
            UUPSUpgradeable.upgradeToAndCall,
            (address(impl), innerCalldata)
        );

        console.log("=== Upgrade payload - submit via Gnosis Safe ===");
        console.log("Proxy address (the 'To' field in Safe):");
        console.logAddress(PROXY);
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
