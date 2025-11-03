// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "./interfaces/IEAS.sol";
import "./libraries/Capabilities.sol";

/**
 * @title AttestationAccessControlV6
 * @notice Base contract for attestation-based access control
 *
 * Provides capability verification using EAS (Ethereum Attestation Service) attestations
 * instead of ZK proofs. This eliminates circuit complexity while maintaining strong
 * cryptographic guarantees through EAS's tamper-proof attestation infrastructure.
 *
 * KEY FEATURES:
 * - Capability-based security (bitmask permissions)
 * - EAS attestation verification (cryptographically signed)
 * - Gas efficient (~10k vs ~150k for ZK proofs)
 * - Revocable access (instant capability removal)
 * - Document-scoped permissions (capabilities per document)
 * - Issuer-controlled (document creator grants access)
 *
 * DESIGN PATTERN:
 * All Layer 3+ contracts inherit this for unified access control.
 * Operations are protected with requiresCapability() modifier instead of ZK proofs.
 *
 * ARCHITECTURE:
 * 1. Document issuer verifies identity off-chain (email, DocuSign, video, etc.)
 * 2. Issuer issues EAS attestation granting capabilities
 * 3. User presents attestation UID to smart contract operations
 * 4. Contract verifies attestation is valid and grants required capability
 * 5. User can perform operation (no ZK proof needed)
 *
 * @dev This is an abstract contract. Inheriting contracts must implement their own
 *      business logic while using requiresCapability() for access control.
 */
abstract contract AttestationAccessControlV6 is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using Capabilities for uint256;

    // ============ Constants ============

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // Re-export capability constants for convenience
    uint256 public constant CAPABILITY_CLAIM_TOKEN = Capabilities.CLAIM_TOKEN;
    uint256 public constant CAPABILITY_TRANSFER_TOKEN = Capabilities.TRANSFER_TOKEN;
    uint256 public constant CAPABILITY_REQUEST_PAYMENT = Capabilities.REQUEST_PAYMENT;
    uint256 public constant CAPABILITY_APPROVE_PAYMENT = Capabilities.APPROVE_PAYMENT;
    uint256 public constant CAPABILITY_UPDATE_METADATA = Capabilities.UPDATE_METADATA;
    uint256 public constant CAPABILITY_DELEGATE_RIGHTS = Capabilities.DELEGATE_RIGHTS;
    uint256 public constant CAPABILITY_REVOKE_ACCESS = Capabilities.REVOKE_ACCESS;
    uint256 public constant CAPABILITY_ADMIN = Capabilities.ADMIN;

    // ============ State Variables ============

    /// @notice EAS contract instance
    IEAS public eas;

    /// @notice Access capability schema UID
    /// @dev Defines structure of capability attestations
    bytes32 public accessCapabilitySchema;

    /// @notice Document issuers (who can grant capabilities)
    /// @dev Maps integraHash → issuer address
    mapping(bytes32 => address) public documentIssuers;

    // ============ Events ============

    event CapabilityVerified(
        address indexed user,
        bytes32 indexed documentHash,
        uint256 capabilities,
        bytes32 indexed attestationUID
    );

    event DocumentIssuerSet(
        bytes32 indexed documentHash,
        address indexed issuer,
        uint256 timestamp
    );

    event AccessCapabilitySchemaUpdated(
        bytes32 indexed oldSchema,
        bytes32 indexed newSchema,
        uint256 timestamp
    );

    // ============ Errors ============

    error NoCapability(address user, bytes32 documentHash, uint256 requiredCapability);
    error AttestationNotFound(bytes32 attestationUID);
    error AttestationRevoked(bytes32 attestationUID, uint64 revokedAt);
    error AttestationExpired(bytes32 attestationUID, uint64 expiredAt);
    error InvalidIssuer(address attester, address expectedIssuer);
    error InvalidRecipient(address recipient, address expectedRecipient);
    error InvalidSchema(bytes32 schema, bytes32 expectedSchema);
    error WrongDocument(bytes32 attestedDoc, bytes32 expectedDoc);
    error DocumentIssuerNotSet(bytes32 documentHash);
    error InvalidEASAddress();
    error InvalidSchemaUID();
    error InvalidIssuerAddress();

    // ============ Modifiers ============

    /**
     * @notice Verify caller has required capability via attestation
     * @param documentHash Document identifier (integraHash)
     * @param requiredCapability Capability flag(s) required
     * @param attestationUID EAS attestation UID proving capability
     *
     * @dev Usage:
     *   function claimToken(bytes32 integraHash, uint256 tokenId, bytes32 attestationUID)
     *       external
     *       requiresCapability(integraHash, CAPABILITY_CLAIM_TOKEN, attestationUID)
     *   {
     *       // Function body - capability verified
     *   }
     */
    modifier requiresCapability(
        bytes32 documentHash,
        uint256 requiredCapability,
        bytes32 attestationUID
    ) {
        _verifyCapability(msg.sender, documentHash, requiredCapability, attestationUID);
        _;
    }

    // ============ Initialization ============

    /**
     * @notice Initialize attestation access control
     * @param _eas EAS contract address
     * @param _accessCapabilitySchema Schema UID for capability attestations
     *
     * @dev Called by inheriting contract's initialize function
     */
    function __AttestationAccessControl_init(
        address _eas,
        bytes32 _accessCapabilitySchema
    ) internal onlyInitializing {
        if (_eas == address(0)) revert InvalidEASAddress();
        if (_accessCapabilitySchema == bytes32(0)) revert InvalidSchemaUID();

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        eas = IEAS(_eas);
        accessCapabilitySchema = _accessCapabilitySchema;
    }

    // ============ Core Verification ============

    /**
     * @notice Internal capability verification
     * @param user Address claiming capability
     * @param documentHash Document identifier
     * @param requiredCapability Required capability flags
     * @param attestationUID EAS attestation UID
     *
     * @dev Performs comprehensive checks:
     *   1. Attestation exists
     *   2. Not revoked
     *   3. Not expired
     *   4. Schema matches
     *   5. Recipient matches caller
     *   6. Attester is document issuer
     *   7. Document hash matches
     *   8. Capabilities include required
     */
    function _verifyCapability(
        address user,
        bytes32 documentHash,
        uint256 requiredCapability,
        bytes32 attestationUID
    ) internal {
        // Get attestation from EAS
        IEAS.Attestation memory attestation = eas.getAttestation(attestationUID);

        // Verify attestation exists
        if (attestation.uid == bytes32(0)) {
            revert AttestationNotFound(attestationUID);
        }

        // Verify not revoked
        if (attestation.revocationTime != 0) {
            revert AttestationRevoked(attestationUID, attestation.revocationTime);
        }

        // Verify not expired
        if (attestation.expirationTime != 0 && attestation.expirationTime < block.timestamp) {
            revert AttestationExpired(attestationUID, attestation.expirationTime);
        }

        // Verify schema matches expected capability schema
        if (attestation.schema != accessCapabilitySchema) {
            revert InvalidSchema(attestation.schema, accessCapabilitySchema);
        }

        // Verify recipient is the caller
        if (attestation.recipient != user) {
            revert InvalidRecipient(attestation.recipient, user);
        }

        // Verify attester is document issuer
        address issuer = documentIssuers[documentHash];
        if (issuer == address(0)) {
            revert DocumentIssuerNotSet(documentHash);
        }
        if (attestation.attester != issuer) {
            revert InvalidIssuer(attestation.attester, issuer);
        }

        // Decode attestation data
        // Schema: bytes32 documentHash, uint256 tokenId, uint256 capabilities,
        //         string verifiedIdentity, string verificationMethod, uint256 verificationDate,
        //         string contractRole, string legalEntityType, string notes
        (
            bytes32 attestedDocHash,
            ,  // tokenId (not used in capability check)
            uint256 grantedCapabilities,
            ,  // verifiedIdentity (not used)
            ,  // verificationMethod (not used)
            ,  // verificationDate (not used)
            ,  // contractRole (not used)
            ,  // legalEntityType (not used)
               // notes (not used)
        ) = abi.decode(
            attestation.data,
            (bytes32, uint256, uint256, string, string, uint256, string, string, string)
        );

        // Verify document hash matches
        if (attestedDocHash != documentHash) {
            revert WrongDocument(attestedDocHash, documentHash);
        }

        // Verify capabilities include required (using library helper)
        if (!grantedCapabilities.hasCapability(requiredCapability)) {
            revert NoCapability(user, documentHash, requiredCapability);
        }

        // Emit event for monitoring and analytics
        emit CapabilityVerified(user, documentHash, grantedCapabilities, attestationUID);
    }

    // ============ View Functions ============

    /**
     * @notice Check if address has capability (view function for UI)
     * @param user Address to check
     * @param documentHash Document identifier
     * @param requiredCapability Required capability
     * @param attestationUID Attestation UID
     * @return hasCapability Whether user has required capability
     * @return grantedCapabilities All capabilities user has (bitmask)
     * @return attestationData Decoded attestation information
     *
     * @dev Non-reverting version for frontend queries
     */
    function checkCapability(
        address user,
        bytes32 documentHash,
        uint256 requiredCapability,
        bytes32 attestationUID
    ) external view returns (
        bool hasCapability,
        uint256 grantedCapabilities,
        AttestationData memory attestationData
    ) {
        try this._verifyCapabilityExternal(user, documentHash, requiredCapability, attestationUID) {
            // Get attestation to return details
            IEAS.Attestation memory attestation = eas.getAttestation(attestationUID);

            (
                bytes32 attestedDocHash,
                uint256 tokenId,
                uint256 caps,
                string memory verifiedIdentity,
                string memory verificationMethod,
                uint256 verificationDate,
                string memory contractRole,
                string memory legalEntityType,
                string memory notes
            ) = abi.decode(
                attestation.data,
                (bytes32, uint256, uint256, string, string, uint256, string, string, string)
            );

            attestationData = AttestationData({
                documentHash: attestedDocHash,
                tokenId: tokenId,
                capabilities: caps,
                verifiedIdentity: verifiedIdentity,
                verificationMethod: verificationMethod,
                verificationDate: verificationDate,
                contractRole: contractRole,
                legalEntityType: legalEntityType,
                notes: notes,
                attester: attestation.attester,
                recipient: attestation.recipient,
                issuedAt: attestation.time,
                expiresAt: attestation.expirationTime,
                revokedAt: attestation.revocationTime
            });

            return (true, caps, attestationData);
        } catch {
            return (false, 0, AttestationData({
                documentHash: bytes32(0),
                tokenId: 0,
                capabilities: 0,
                verifiedIdentity: "",
                verificationMethod: "",
                verificationDate: 0,
                contractRole: "",
                legalEntityType: "",
                notes: "",
                attester: address(0),
                recipient: address(0),
                issuedAt: 0,
                expiresAt: 0,
                revokedAt: 0
            }));
        }
    }

    /**
     * @notice External wrapper for view capability check
     * @dev Needed for try/catch in checkCapability()
     */
    function _verifyCapabilityExternal(
        address user,
        bytes32 documentHash,
        uint256 requiredCapability,
        bytes32 attestationUID
    ) external view {
        _verifyCapabilityView(user, documentHash, requiredCapability, attestationUID);
    }

    /**
     * @notice Internal capability verification (view-only, no events)
     * @dev Used by view functions - identical to _verifyCapability but without event emission
     */
    function _verifyCapabilityView(
        address user,
        bytes32 documentHash,
        uint256 requiredCapability,
        bytes32 attestationUID
    ) internal view {
        // Get attestation from EAS
        IEAS.Attestation memory attestation = eas.getAttestation(attestationUID);

        // Verify attestation is valid
        if (attestation.uid == bytes32(0)) {
            revert AttestationNotFound(attestationUID);
        }

        // Check not expired
        if (attestation.expirationTime > 0 && block.timestamp > attestation.expirationTime) {
            revert AttestationExpired(attestationUID, attestation.expirationTime);
        }

        // Check not revoked
        if (attestation.revocationTime > 0) {
            revert AttestationRevoked(attestationUID, attestation.revocationTime);
        }

        // Verify schema matches
        if (attestation.schema != accessCapabilitySchema) {
            revert InvalidSchema(attestation.schema, accessCapabilitySchema);
        }

        // Verify recipient matches user
        if (attestation.recipient != user) {
            revert InvalidRecipient(attestation.recipient, user);
        }

        // Verify attester is document issuer
        address issuer = documentIssuers[documentHash];
        if (issuer == address(0)) {
            revert DocumentIssuerNotSet(documentHash);
        }
        if (attestation.attester != issuer) {
            revert InvalidIssuer(attestation.attester, issuer);
        }

        // Decode attestation data
        (
            bytes32 attestedDocHash,
            ,
            uint256 grantedCapabilities,
            ,,,,,
        ) = abi.decode(
            attestation.data,
            (bytes32, uint256, uint256, string, string, uint256, string, string, string)
        );

        // Verify document hash matches
        if (attestedDocHash != documentHash) {
            revert WrongDocument(attestedDocHash, documentHash);
        }

        // Verify capabilities include required
        if (!grantedCapabilities.hasCapability(requiredCapability)) {
            revert NoCapability(user, documentHash, requiredCapability);
        }

        // Note: No event emission in view function
    }

    /**
     * @notice Get all capability constants
     * @return Array of all capability flags
     *
     * @dev Useful for UI and testing
     */
    function getAllCapabilities() external pure returns (uint256[8] memory) {
        return [
            CAPABILITY_CLAIM_TOKEN,
            CAPABILITY_TRANSFER_TOKEN,
            CAPABILITY_REQUEST_PAYMENT,
            CAPABILITY_APPROVE_PAYMENT,
            CAPABILITY_UPDATE_METADATA,
            CAPABILITY_DELEGATE_RIGHTS,
            CAPABILITY_REVOKE_ACCESS,
            CAPABILITY_ADMIN
        ];
    }

    /**
     * @notice Get document issuer address
     * @param documentHash Document identifier
     * @return Issuer address (or address(0) if not set)
     */
    function getDocumentIssuer(bytes32 documentHash) external view returns (address) {
        return documentIssuers[documentHash];
    }

    // ============ Admin Functions ============

    /**
     * @notice Set document issuer (who can grant capabilities)
     * @param documentHash Document identifier (integraHash)
     * @param issuer Address of document issuer
     *
     * @dev Called by document registry during registration
     *      Only executor (Layer 2 registry) can set issuer
     */
    function setDocumentIssuer(
        bytes32 documentHash,
        address issuer
    ) external onlyRole(EXECUTOR_ROLE) {
        if (issuer == address(0)) revert InvalidIssuerAddress();

        documentIssuers[documentHash] = issuer;

        emit DocumentIssuerSet(documentHash, issuer, block.timestamp);
    }

    /**
     * @notice Update access capability schema
     * @param newSchema New schema UID
     *
     * @dev Only governor can update schema
     *      Use with caution - changing schema invalidates existing attestations
     */
    function updateAccessCapabilitySchema(
        bytes32 newSchema
    ) external onlyRole(GOVERNOR_ROLE) {
        if (newSchema == bytes32(0)) revert InvalidSchemaUID();

        bytes32 oldSchema = accessCapabilitySchema;
        accessCapabilitySchema = newSchema;

        emit AccessCapabilitySchemaUpdated(oldSchema, newSchema, block.timestamp);
    }

    // ============ Internal Helpers ============

    /**
     * @notice Decode attestation data
     * @param attestationData Raw attestation data bytes
     * @return documentHash Document hash from attestation
     * @return tokenId Token ID from attestation
     * @return capabilities Capability bitmask from attestation
     *
     * @dev Helper for contracts that need to access attestation details
     */
    function _decodeAttestationData(bytes memory attestationData)
        internal
        pure
        returns (
            bytes32 documentHash,
            uint256 tokenId,
            uint256 capabilities,
            string memory verifiedIdentity,
            string memory verificationMethod,
            uint256 verificationDate,
            string memory contractRole,
            string memory legalEntityType,
            string memory notes
        )
    {
        return abi.decode(
            attestationData,
            (bytes32, uint256, uint256, string, string, uint256, string, string, string)
        );
    }

    // ============ UUPS Upgrade Authorization ============

    /**
     * @notice Authorize contract upgrade
     * @dev Only governor can authorize upgrades
     *      Virtual to allow inheriting contracts to override if needed
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        virtual
        override
        onlyRole(GOVERNOR_ROLE)
    {}

    // ============ Data Structures ============

    /**
     * @notice Decoded attestation data structure
     * @dev Used for returning attestation information to frontends
     */
    struct AttestationData {
        bytes32 documentHash;
        uint256 tokenId;
        uint256 capabilities;
        string verifiedIdentity;
        string verificationMethod;
        uint256 verificationDate;
        string contractRole;
        string legalEntityType;
        string notes;
        address attester;
        address recipient;
        uint64 issuedAt;
        uint64 expiresAt;
        uint64 revokedAt;
    }

    // ============ Storage Gap ============

    /**
     * @dev Storage gap for future upgrades
     * Reserves 50 slots for additional state variables
     */
    uint256[47] private __gap;
}
