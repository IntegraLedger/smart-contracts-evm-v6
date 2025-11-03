// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IEAS
 * @notice Interface for Ethereum Attestation Service
 * @dev Based on EAS v1.3.0 - https://github.com/ethereum-attestation-service/eas-contracts
 *
 * EAS provides a universal attestation infrastructure where any entity can make
 * verifiable attestations about any subject. Attestations are stored on-chain and
 * cryptographically signed, making them tamper-proof and publicly verifiable.
 *
 * Official deployments:
 * - Ethereum: 0xA1207F3BBa224E2c9c3c6D5aF63D0eb1582Ce587
 * - Optimism: 0x4200000000000000000000000000000000000021
 * - Base: 0x4200000000000000000000000000000000000021
 * - Sepolia: 0xC2679fBD37d54388Ce493F1DB75320D236e1815e
 */
interface IEAS {
    // ============ Structs ============

    /**
     * @notice Attestation structure
     * @dev Contains all data about an attestation
     */
    struct Attestation {
        bytes32 uid;              // Unique attestation identifier
        bytes32 schema;           // Schema UID defining attestation structure
        uint64 time;              // Timestamp when attestation was created
        uint64 expirationTime;    // Expiration timestamp (0 for no expiration)
        uint64 revocationTime;    // Revocation timestamp (0 if not revoked)
        bytes32 refUID;           // Referenced attestation UID (0 if none)
        address recipient;        // Address attestation is about
        address attester;         // Address that made the attestation
        bool revocable;           // Whether attestation can be revoked
        bytes data;               // ABI-encoded attestation data
    }

    /**
     * @notice Attestation request structure
     * @dev Used when creating new attestations
     */
    struct AttestationRequest {
        bytes32 schema;           // Schema UID
        AttestationRequestData data;
    }

    /**
     * @notice Attestation request data
     */
    struct AttestationRequestData {
        address recipient;        // Attestation recipient
        uint64 expirationTime;    // Expiration time (0 for none)
        bool revocable;           // Can be revoked?
        bytes32 refUID;           // Referenced attestation (0 for none)
        bytes data;               // ABI-encoded data
        uint256 value;            // ETH value to send (for payable attestations)
    }

    /**
     * @notice Multi-attestation request
     */
    struct MultiAttestationRequest {
        bytes32 schema;
        AttestationRequestData[] data;
    }

    /**
     * @notice Revocation request structure
     */
    struct RevocationRequest {
        bytes32 schema;           // Schema UID
        RevocationRequestData data;
    }

    /**
     * @notice Revocation request data
     */
    struct RevocationRequestData {
        bytes32 uid;              // Attestation UID to revoke
        uint256 value;            // ETH value (for payable revocations)
    }

    /**
     * @notice Multi-revocation request
     */
    struct MultiRevocationRequest {
        bytes32 schema;
        RevocationRequestData[] data;
    }

    // ============ Events ============

    event Attested(
        address indexed recipient,
        address indexed attester,
        bytes32 uid,
        bytes32 indexed schema
    );

    event Revoked(
        address indexed recipient,
        address indexed attester,
        bytes32 uid,
        bytes32 indexed schema
    );

    event Timestamped(bytes32 indexed data, uint64 indexed timestamp);

    // ============ Read Functions ============

    /**
     * @notice Get attestation by UID
     * @param uid Attestation unique identifier
     * @return Attestation struct
     */
    function getAttestation(bytes32 uid) external view returns (Attestation memory);

    /**
     * @notice Check if attestation exists
     * @param uid Attestation UID
     * @return Whether attestation exists
     */
    function isAttestationValid(bytes32 uid) external view returns (bool);

    /**
     * @notice Get timestamp for data
     * @param data Data that was timestamped
     * @return Timestamp
     */
    function getTimestamp(bytes32 data) external view returns (uint64);

    // ============ Write Functions ============

    /**
     * @notice Create attestation
     * @param request Attestation request
     * @return Attestation UID
     */
    function attest(AttestationRequest calldata request) external payable returns (bytes32);

    /**
     * @notice Create multiple attestations
     * @param multiRequests Array of attestation requests
     * @return Array of attestation UIDs
     */
    function multiAttest(MultiAttestationRequest[] calldata multiRequests)
        external
        payable
        returns (bytes32[] memory);

    /**
     * @notice Revoke attestation
     * @param request Revocation request
     */
    function revoke(RevocationRequest calldata request) external payable;

    /**
     * @notice Revoke multiple attestations
     * @param multiRequests Array of revocation requests
     */
    function multiRevoke(MultiRevocationRequest[] calldata multiRequests) external payable;

    /**
     * @notice Timestamp data
     * @param data Data to timestamp
     * @return Timestamp
     */
    function timestamp(bytes32 data) external returns (uint64);

    /**
     * @notice Timestamp multiple data
     * @param data Array of data to timestamp
     * @return Array of timestamps
     */
    function multiTimestamp(bytes32[] calldata data) external returns (uint64[] memory);

    // ============ Delegation Functions ============

    /**
     * @notice Create attestation on behalf of attester (delegated)
     * @dev Requires valid signature from attester
     */
    function attestByDelegation(
        AttestationRequest calldata request,
        bytes calldata signature
    ) external payable returns (bytes32);

    /**
     * @notice Revoke attestation on behalf of attester (delegated)
     * @dev Requires valid signature from attester
     */
    function revokeByDelegation(
        RevocationRequest calldata request,
        bytes calldata signature
    ) external payable;
}
