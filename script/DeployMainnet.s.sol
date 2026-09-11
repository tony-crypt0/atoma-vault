// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/AtomaVault.sol";

contract DeployMainnet is Script {
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 constant INITIAL_MAX_TVL = 10_000e6; // 10,000 USDC ($10k cap, 6 decimals)
    uint256 constant ETH_PRICE_USD = 2300;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");
        string memory name_ = vm.envOr("NAME", string("Atoma Vault Share"));
        string memory symbol_ = vm.envOr("SYMBOL", string("AVS"));
        address deployer = vm.addr(deployerPk);

        require(operator != address(0), "OPERATOR_ADDRESS unset");
        require(owner != address(0), "OWNER_ADDRESS unset");

        uint256 startGas = gasleft();

        vm.startBroadcast(deployerPk);

        AtomaVault impl = new AtomaVault();

        bytes memory initData = abi.encodeCall(
            AtomaVault.initialize,
            (IERC20(USDC), deployer, operator, name_, symbol_)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        AtomaVault vault = AtomaVault(address(proxy));

        vault.setMaxTotalAssets(INITIAL_MAX_TVL);
        vault.transferOwnership(owner);

        require(vault.owner() == owner, "ownership transfer failed");
        require(vault.operator() == operator, "operator mismatch");
        require(vault.asset() == USDC, "asset mismatch");
        require(vault.maxTotalAssets() == INITIAL_MAX_TVL, "cap mismatch");

        vm.stopBroadcast();

        uint256 gasUsed = startGas - gasleft();
        uint256 gasPrice = tx.gasprice == 0 ? 0.04 gwei : tx.gasprice;
        uint256 weiCost = gasUsed * gasPrice;
        uint256 usdCents = (weiCost * ETH_PRICE_USD * 100) / 1e18;

        console.log("=== AtomaVault deployed to Arbitrum One ===");
        console.log("Implementation:", address(impl));
        console.log("Proxy (vault):", address(proxy));
        console.log("Owner:", vault.owner());
        console.log("Operator:", vault.operator());
        console.log("USDC:", vault.asset());
        console.log("Max TVL:", vault.maxTotalAssets());
        console.log("--- Cost (ETH assumed @ $2300) ---");
        console.log("Gas used:", gasUsed);
        console.log("Gas price (wei):", gasPrice);
        console.log("ETH cost (wei):", weiCost);
        console.log("USD cost (cents):", usdCents);
    }
}
