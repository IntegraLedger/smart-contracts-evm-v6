// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/layer4/IntegraMessageV6.sol";
import "../src/layer4/IntegraSignalV6.sol";
import "../src/layer6/IntegraExecutorV6.sol";
import "../src/layer6/IntegraTokenGatewayV6.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployRemaining
 * @notice Deploy remaining V6 contracts (Layer 4 + Layer 6)
 */
contract DeployRemaining is Script {
    address governor;
    address easAddress;
    address documentRegistryAddress;
    address verifierRegistryAddress;

    // Placeholder for Integra token (if you don't have one, deploy a mock)
    address integraTokenAddress = address(0); // UPDATE THIS or deploy mock token

    bytes32 messageSchema = keccak256("INTEGRA_V6_MESSAGE_PLACEHOLDER");
    bytes32 payloadSchema = keccak256("INTEGRA_V6_PAYLOAD_PLACEHOLDER");

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        governor = vm.addr(deployerPrivateKey);
        easAddress = vm.envAddress("POLYGON_EAS");

        // Read deployed addresses from environment or hardcode
        documentRegistryAddress = 0x8609E5627933665D4576aAE992b13465fedecBde;
        verifierRegistryAddress = 0x4A6EBd1f4Ac78A58632f7009f43AB087810335CC;

        console.log("Deploying Layer 4 + Layer 6 to Polygon");
        console.log("Governor:", governor);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============ Layer 4: IntegraMessageV6 ============

        console.log("1. Deploying IntegraMessageV6...");
        IntegraMessageV6 messageImpl = new IntegraMessageV6();
        console.log("  Implementation:", address(messageImpl));

        bytes memory messageInitData = abi.encodeWithSelector(
            IntegraMessageV6.initialize.selector,
            verifierRegistryAddress,
            governor
        );
        ERC1967Proxy messageProxy = new ERC1967Proxy(address(messageImpl), messageInitData);
        IntegraMessageV6 messageContract = IntegraMessageV6(address(messageProxy));
        console.log("  Proxy:", address(messageContract));
        console.log("");

        // ============ Layer 4: IntegraSignalV6 ============

        console.log("2. Deploying IntegraSignalV6...");
        IntegraSignalV6 signalImpl = new IntegraSignalV6();
        console.log("  Implementation:", address(signalImpl));

        bytes memory signalInitData = abi.encodeWithSelector(
            IntegraSignalV6.initialize.selector,
            documentRegistryAddress,
            easAddress,
            payloadSchema,
            governor
        );
        ERC1967Proxy signalProxy = new ERC1967Proxy(address(signalImpl), signalInitData);
        IntegraSignalV6 signalContract = IntegraSignalV6(address(signalProxy));
        console.log("  Proxy:", address(signalContract));
        console.log("");

        // ============ Layer 6: IntegraExecutorV6 ============

        console.log("3. Deploying IntegraExecutorV6...");

        // IntegraExecutorV6 requires trusted forwarder in constructor
        // Using deployer as placeholder trusted forwarder
        address trustedForwarder = governor;

        IntegraExecutorV6 executorImpl = new IntegraExecutorV6(trustedForwarder);
        console.log("  Implementation:", address(executorImpl));

        bytes memory executorInitData = abi.encodeWithSelector(
            IntegraExecutorV6.initialize.selector,
            governor,      // governor
            governor       // fee recipient (same as governor for now)
        );
        ERC1967Proxy executorProxy = new ERC1967Proxy(address(executorImpl), executorInitData);
        IntegraExecutorV6 executor = IntegraExecutorV6(payable(address(executorProxy)));
        console.log("  Proxy:", address(executor));
        console.log("");

        // ============ Layer 6: IntegraTokenGatewayV6 ============

        if (integraTokenAddress != address(0)) {
            console.log("4. Deploying IntegraTokenGatewayV6...");
            IntegraTokenGatewayV6 gatewayImpl = new IntegraTokenGatewayV6();
            console.log("  Implementation:", address(gatewayImpl));

            bytes memory gatewayInitData = abi.encodeWithSelector(
                IntegraTokenGatewayV6.initialize.selector,
                integraTokenAddress,  // Integra token
                governor,              // treasury
                governor               // governor
            );
            ERC1967Proxy gatewayProxy = new ERC1967Proxy(address(gatewayImpl), gatewayInitData);
            IntegraTokenGatewayV6 gateway = IntegraTokenGatewayV6(address(gatewayProxy));
            console.log("  Proxy:", address(gateway));
            console.log("");
        } else {
            console.log("4. Skipping IntegraTokenGatewayV6 (no Integra token address provided)");
            console.log("");
        }

        vm.stopBroadcast();

        console.log("==================================================");
        console.log("REMAINING CONTRACTS DEPLOYMENT COMPLETE");
        console.log("==================================================");
        console.log("");
        console.log("IntegraMessageV6:", address(messageContract));
        console.log("IntegraSignalV6:", address(signalContract));
        console.log("IntegraExecutorV6:", address(executor));

        // Save addresses
        string memory deploymentInfo = string.concat(
            "# Layer 4 + Layer 6 - Polygon Deployment\n\n",
            "IntegraMessageV6_Proxy: ", vm.toString(address(messageContract)), "\n",
            "IntegraMessageV6_Implementation: ", vm.toString(address(messageImpl)), "\n\n",
            "IntegraSignalV6_Proxy: ", vm.toString(address(signalContract)), "\n",
            "IntegraSignalV6_Implementation: ", vm.toString(address(signalImpl)), "\n\n",
            "IntegraExecutorV6_Proxy: ", vm.toString(address(executor)), "\n",
            "IntegraExecutorV6_Implementation: ", vm.toString(address(executorImpl)), "\n"
        );

        vm.writeFile("./deployments/polygon-layer4-layer6.txt", deploymentInfo);
    }
}
