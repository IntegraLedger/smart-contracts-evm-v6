// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./mocks/MockEAS.sol";

/**
 * @title BaseResolverTest
 * @notice Base test contract with helper functions for resolver testing
 */
abstract contract BaseResolverTest is Test {
    MockEAS public eas;

    address public governor = address(0x1);
    address public executor = address(0x2);
    address public operator = address(0x3);
    address public issuer = address(0x4);
    address public user1 = address(0x5);
    address public user2 = address(0x6);

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    bytes32 public capabilitySchema = keccak256("capabilitySchema");
    bytes32 public credentialSchema = keccak256("credentialSchema");

    /**
     * @notice Create a properly formatted capability attestation
     * @param attester Attestation issuer (document issuer)
     * @param recipient Attestation recipient
     * @param integraHash Document identifier
     * @param capabilities Capability flags (e.g., 0x01 for CLAIM_TOKEN)
     * @return attestationUID The created attestation UID
     */
    function createCapabilityAttestation(
        address attester,
        address recipient,
        bytes32 integraHash,
        uint256 capabilities
    ) internal returns (bytes32) {
        return createCapabilityAttestation(
            attester,
            recipient,
            integraHash,
            capabilities,
            "Test User",
            "Email Verification"
        );
    }

    /**
     * @notice Create a capability attestation with custom identity info
     */
    function createCapabilityAttestation(
        address attester,
        address recipient,
        bytes32 integraHash,
        uint256 capabilities,
        string memory verifiedIdentity,
        string memory verificationMethod
    ) internal returns (bytes32) {
        IEAS.AttestationRequest memory request = IEAS.AttestationRequest({
            schema: capabilitySchema,
            data: IEAS.AttestationRequestData({
                recipient: recipient,
                expirationTime: uint64(block.timestamp + 365 days),
                revocable: true,
                refUID: bytes32(0),
                data: abi.encode(
                    integraHash,                    // documentHash
                    uint256(0),                     // tokenId
                    capabilities,                   // capabilities bitmask
                    verifiedIdentity,               // verifiedIdentity
                    verificationMethod,             // verificationMethod
                    block.timestamp,                // verificationDate
                    "Token Holder",                 // contractRole
                    "Individual",                   // legalEntityType
                    "Test attestation"              // notes
                ),
                value: 0
            })
        });

        vm.prank(attester);
        return eas.attest(request);
    }

    /**
     * @notice Create an expired attestation for testing expiration logic
     */
    function createExpiredAttestation(
        address attester,
        address recipient,
        bytes32 integraHash,
        uint256 capabilities
    ) internal returns (bytes32) {
        IEAS.AttestationRequest memory request = IEAS.AttestationRequest({
            schema: capabilitySchema,
            data: IEAS.AttestationRequestData({
                recipient: recipient,
                expirationTime: uint64(block.timestamp - 1),  // Already expired
                revocable: true,
                refUID: bytes32(0),
                data: abi.encode(
                    integraHash,
                    uint256(0),
                    capabilities,
                    "Test User",
                    "Test Verification",
                    block.timestamp,
                    "Token Holder",
                    "Individual",
                    "Expired attestation"
                ),
                value: 0
            })
        });

        vm.prank(attester);
        return eas.attest(request);
    }

    /**
     * @notice Setup EAS mock
     */
    function setupEAS() internal {
        eas = new MockEAS();
    }
}
