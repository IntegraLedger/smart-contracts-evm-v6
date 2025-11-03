// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/layer3/OwnershipResolverV6.sol";
import "../src/layer3/SharesResolverV6.sol";
import "../src/layer3/MultiPartyResolverV6.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployLayer3
 * @notice Deploy Layer 3 resolver contracts on Polygon
 *
 * REQUIRES:
 * - IntegraDocumentRegistryV6 already deployed
 * - EAS address on Polygon
 * - Schema UIDs registered (or use bytes32(0) as placeholder)
 */
contract DeployLayer3 is Script {
    address governor;
    address easAddress;

    // Placeholder schemas - update after EAS schema registration
    // Using non-zero placeholder (can update later via setAccessCapabilitySchema)
    bytes32 accessCapabilitySchema = keccak256("INTEGRA_V6_ACCESS_CAPABILITY_PLACEHOLDER");
    bytes32 credentialSchema = keccak256("INTEGRA_V6_CREDENTIAL_PLACEHOLDER");

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        governor = vm.addr(deployerPrivateKey);
        easAddress = vm.envAddress("POLYGON_EAS");

        console.log("Deploying Layer 3 Resolvers to Polygon");
        console.log("Governor:", governor);
        console.log("EAS:", easAddress);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============ Deploy OwnershipResolverV6 (ERC-721) ============

        console.log("1. Deploying OwnershipResolverV6 (ERC-721 for single ownership)...");

        OwnershipResolverV6 ownershipImpl = new OwnershipResolverV6();
        console.log("  Implementation:", address(ownershipImpl));

        bytes memory ownershipInitData = abi.encodeWithSelector(
            OwnershipResolverV6.initialize.selector,
            "Integra Ownership Token V6",  // name
            "IOT-V6",                       // symbol
            "https://integra.global/nft/",  // baseURI
            governor,                        // governor
            easAddress,                      // EAS
            accessCapabilitySchema,          // capability schema
            credentialSchema,                // credential schema
            address(0)                       // trust registry (disabled for now)
        );
        ERC1967Proxy ownershipProxy = new ERC1967Proxy(address(ownershipImpl), ownershipInitData);
        OwnershipResolverV6 ownershipResolver = OwnershipResolverV6(address(ownershipProxy));
        console.log("  Proxy:", address(ownershipResolver));
        console.log("");

        // ============ Deploy SharesResolverV6 (ERC-20 Votes) ============

        console.log("2. Deploying SharesResolverV6 (ERC-20 Votes for fractional ownership)...");

        SharesResolverV6 sharesImpl = new SharesResolverV6();
        console.log("  Implementation:", address(sharesImpl));

        bytes memory sharesInitData = abi.encodeWithSelector(
            SharesResolverV6.initialize.selector,
            "Integra Shares V6",    // name
            "ISH-V6",                // symbol
            governor,                 // governor
            easAddress,               // EAS
            accessCapabilitySchema,   // capability schema
            credentialSchema,         // credential schema
            address(0)                // trust registry (disabled for now)
        );
        ERC1967Proxy sharesProxy = new ERC1967Proxy(address(sharesImpl), sharesInitData);
        SharesResolverV6 sharesResolver = SharesResolverV6(address(sharesProxy));
        console.log("  Proxy:", address(sharesResolver));
        console.log("");

        // ============ Deploy MultiPartyResolverV6 (ERC-1155) ============

        console.log("3. Deploying MultiPartyResolverV6 (ERC-1155 for multi-stakeholder)...");

        MultiPartyResolverV6 multiPartyImpl = new MultiPartyResolverV6();
        console.log("  Implementation:", address(multiPartyImpl));

        bytes memory multiPartyInitData = abi.encodeWithSelector(
            MultiPartyResolverV6.initialize.selector,
            "https://integra.global/token/{id}.json",  // baseURI
            governor,                                   // governor
            easAddress,                                 // EAS
            accessCapabilitySchema,                     // capability schema
            credentialSchema,                           // credential schema
            address(0)                                  // trust registry (disabled for now)
        );
        ERC1967Proxy multiPartyProxy = new ERC1967Proxy(address(multiPartyImpl), multiPartyInitData);
        MultiPartyResolverV6 multiPartyResolver = MultiPartyResolverV6(address(multiPartyProxy));
        console.log("  Proxy:", address(multiPartyResolver));
        console.log("");

        vm.stopBroadcast();

        // ============ Summary ============

        console.log("==================================================");
        console.log("LAYER 3 RESOLVERS DEPLOYMENT COMPLETE");
        console.log("==================================================");
        console.log("");
        console.log("OwnershipResolverV6 (ERC-721):");
        console.log("  Proxy:", address(ownershipResolver));
        console.log("");
        console.log("SharesResolverV6 (ERC-20 Votes):");
        console.log("  Proxy:", address(sharesResolver));
        console.log("");
        console.log("MultiPartyResolverV6 (ERC-1155):");
        console.log("  Proxy:", address(multiPartyResolver));
        console.log("");
        console.log("Governor:", governor);
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Register EAS schemas at https://polygon.easscan.org/schema/create");
        console.log("2. Update schemas via setAccessCapabilitySchema() on each resolver");
        console.log("3. Approve resolvers on IntegraDocumentRegistryV6");
        console.log("4. Deploy Layer 4 contracts (IntegraMessageV6, IntegraSignalV6)");

        // Save addresses
        string memory deploymentInfo = string.concat(
            "# Layer 3 Resolvers - Polygon Deployment\n\n",
            "OwnershipResolverV6_Proxy: ", vm.toString(address(ownershipResolver)), "\n",
            "OwnershipResolverV6_Implementation: ", vm.toString(address(ownershipImpl)), "\n\n",
            "SharesResolverV6_Proxy: ", vm.toString(address(sharesResolver)), "\n",
            "SharesResolverV6_Implementation: ", vm.toString(address(sharesImpl)), "\n\n",
            "MultiPartyResolverV6_Proxy: ", vm.toString(address(multiPartyResolver)), "\n",
            "MultiPartyResolverV6_Implementation: ", vm.toString(address(multiPartyImpl)), "\n"
        );

        vm.writeFile("./deployments/polygon-layer3.txt", deploymentInfo);
    }
}
