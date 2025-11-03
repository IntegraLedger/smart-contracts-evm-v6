// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/layer6/IntegraVerifierRegistryV6.sol";
import "../src/layer2/IntegraDocumentRegistryV6.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployV6
 * @notice Deployment script for Integra V6 contracts on Polygon
 *
 * DEPLOYMENT ORDER:
 * 1. IntegraVerifierRegistryV6 (infrastructure - no dependencies)
 * 2. IntegraDocumentRegistryV6 (depends on verifier registry)
 *
 * Usage:
 *   forge script script/DeployV6.s.sol:DeployV6 --rpc-url $POLYGON_RPC --broadcast --verify
 */
contract DeployV6 is Script {
    // Deployer will be governor
    address governor;

    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        governor = vm.addr(deployerPrivateKey);

        console.log("Deploying V6 contracts to Polygon");
        console.log("Deployer/Governor:", governor);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============ Step 1: Deploy IntegraVerifierRegistryV6 ============

        console.log("1. Deploying IntegraVerifierRegistryV6...");

        // Deploy implementation
        IntegraVerifierRegistryV6 verifierRegistryImpl = new IntegraVerifierRegistryV6();
        console.log("  Implementation:", address(verifierRegistryImpl));

        // Deploy proxy
        bytes memory verifierInitData = abi.encodeWithSelector(
            IntegraVerifierRegistryV6.initialize.selector,
            governor
        );
        ERC1967Proxy verifierProxy = new ERC1967Proxy(
            address(verifierRegistryImpl),
            verifierInitData
        );
        IntegraVerifierRegistryV6 verifierRegistry = IntegraVerifierRegistryV6(address(verifierProxy));
        console.log("  Proxy:", address(verifierRegistry));
        console.log("");

        // ============ Step 2: Deploy IntegraDocumentRegistryV6 ============

        console.log("2. Deploying IntegraDocumentRegistryV6...");

        // Deploy implementation
        IntegraDocumentRegistryV6 registryImpl = new IntegraDocumentRegistryV6();
        console.log("  Implementation:", address(registryImpl));

        // Deploy proxy
        bytes memory registryInitData = abi.encodeWithSelector(
            IntegraDocumentRegistryV6.initialize.selector,
            governor,
            address(verifierRegistry)
        );
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            registryInitData
        );
        IntegraDocumentRegistryV6 documentRegistry = IntegraDocumentRegistryV6(address(registryProxy));
        console.log("  Proxy:", address(documentRegistry));
        console.log("");

        vm.stopBroadcast();

        // ============ Save Deployment Addresses ============

        console.log("==================================================");
        console.log("V6 CORE DEPLOYMENT COMPLETE");
        console.log("==================================================");
        console.log("");
        console.log("IntegraVerifierRegistryV6:");
        console.log("  Proxy:", address(verifierRegistry));
        console.log("  Implementation:", address(verifierRegistryImpl));
        console.log("");
        console.log("IntegraDocumentRegistryV6:");
        console.log("  Proxy:", address(documentRegistry));
        console.log("  Implementation:", address(registryImpl));
        console.log("");
        console.log("Governor:", governor);
        console.log("");
        console.log("Save these addresses for Layer 3 deployments!");

        // Write to file
        string memory deploymentInfo = string.concat(
            "# V6 Polygon Deployment\n",
            "Chain: Polygon Mainnet (137)\n",
            "Deployer/Governor: ", vm.toString(governor), "\n",
            "\n",
            "## Core Contracts\n",
            "IntegraVerifierRegistryV6_Proxy: ", vm.toString(address(verifierRegistry)), "\n",
            "IntegraVerifierRegistryV6_Implementation: ", vm.toString(address(verifierRegistryImpl)), "\n",
            "\n",
            "IntegraDocumentRegistryV6_Proxy: ", vm.toString(address(documentRegistry)), "\n",
            "IntegraDocumentRegistryV6_Implementation: ", vm.toString(address(registryImpl)), "\n"
        );

        vm.writeFile("./deployments/polygon-v6.txt", deploymentInfo);
        console.log("Deployment addresses saved to: deployments/polygon-v6.txt");
    }
}
