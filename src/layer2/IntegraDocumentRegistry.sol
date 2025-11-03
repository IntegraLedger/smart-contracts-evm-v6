// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../layer6-infrastructure/IntegraVerifierRegistry.sol";

/**
 * @title IntegraDocumentRegistry
 * @notice Core document identity system
 *
 * Accepts integraHash identifiers (generated off-chain using Poseidon).
 * Links documents to tokenization strategies.
 *
 * V6 ARCHITECTURE (Based on V5 Pattern):
 * - integraHash generated off-chain by user (privacy-preserving)
 * - Poseidon hash compatible (ZK-friendly, no split hash needed)
 * - ZK proof required for document references (anti-spam protection)
 * - Encrypted contact data for recipient-issuer communication
 * - Event-based indexing (no reverse lookup arrays)
 * - Ephemeral addresses stored (privacy via Layer 1 identity commitments)
 */
contract IntegraDocumentRegistry is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // ============ Roles ============

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // ============ Constants ============

    uint256 public constant MAX_ENCRYPTED_DATA_LENGTH = 10000; // ~10KB for contact info
    uint256 public constant MAX_DOCUMENTS_PER_BLOCK = 50; // Rate limiting (future use)

    // ============ Types ============

    /**
     * @dev Document record with encrypted contact data
     */
    struct DocumentRecord {
        address owner;
        bytes32 documentHash;
        address resolver;
        bytes32 referencedDocument;
        string encryptedData;  // For recipient-issuer contact mechanism
        uint256 registeredAt;
        bool exists;
    }

    // ============ State ============

    mapping(bytes32 => DocumentRecord) public documents;
    mapping(address => bool) public approvedResolvers;

    // Verifier registry for ZK proof verification
    IntegraVerifierRegistry public verifierRegistry;

    // ============ Storage Gap ============

    // Reserve 50 slots for future upgrades
    // Current: 3 mappings + 1 verifierRegistry + 1 Pausable = 5 slots
    // Gap: 50 - 5 = 45 slots
    uint256[45] private __gap;

    // ============ Events ============

    event DocumentRegistered(
        bytes32 indexed integraHash,
        bytes32 indexed documentHash,
        bytes32 indexed referencedDocument,
        address owner,
        address resolver,
        string encryptedData,
        uint256 timestamp
    );

    event ResolverSet(
        bytes32 indexed integraHash,
        address indexed oldResolver,
        address indexed newResolver,
        uint256 timestamp
    );

    event ResolverApproved(address indexed resolver, bool approved, uint256 timestamp);
    event DocumentReferenced(bytes32 indexed childHash, bytes32 indexed parentHash, uint256 timestamp);
    event DocumentOwnershipTransferred(
        bytes32 indexed integraHash,
        address indexed oldOwner,
        address indexed newOwner,
        string reason,
        uint256 timestamp
    );

    // ============ Errors ============

    // Registration errors
    error DocumentAlreadyRegistered(bytes32 integraHash, address existingOwner);
    error DocumentNotRegistered(bytes32 integraHash);
    error ResolverNotApproved(address resolver);
    error OnlyDocumentOwner(address caller, address owner, bytes32 integraHash);
    error ZeroAddress();
    error InvalidIntegraHash();
    error InvalidDocumentHash();
    error InvalidProof(bytes32 integraHash, address caller);
    error ReferenceDocumentNotFound(bytes32 referencedDocument);
    error VerifierNotFound();

    // Input validation errors
    error EncryptedDataTooLarge(uint256 length, uint256 maximum);

    // Ownership transfer errors
    error InvalidNewOwner();
    error AlreadyTheOwner();
    error OnlyOwnerCanTransfer(address caller, address owner);

    // ============ Init ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _governor,
        address _verifierRegistry
    ) external initializer {
        if (_governor == address(0) || _verifierRegistry == address(0)) {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        verifierRegistry = IntegraVerifierRegistry(_verifierRegistry);

        _grantRole(DEFAULT_ADMIN_ROLE, _governor);
        _grantRole(GOVERNOR_ROLE, _governor);
        _grantRole(OPERATOR_ROLE, _governor);
        _grantRole(EXECUTOR_ROLE, _governor);
    }

    // ============ Emergency Controls ============

    /**
     * @notice Pause all document operations (emergency use only)
     * @dev Pauses registerDocument and setResolver functions
     *      Admin functions (setResolverApproval, transferOwnership) remain active
     *      for emergency response
     */
    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause document operations
     */
    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // ============ Core Functions ============

    /**
     * @notice Register a new document (direct user call)
     * @dev User becomes the document owner
     * @param integraHash Document identifier (generated off-chain by user)
     * @param documentHash Content hash of the document
     * @param resolver Approved tokenization resolver
     * @param referencedDocument Optional reference to parent document (requires zkProof)
     * @param referenceProofA ZK proof component A (required if referencedDocument != 0)
     * @param referenceProofB ZK proof component B (required if referencedDocument != 0)
     * @param referenceProofC ZK proof component C (required if referencedDocument != 0)
     * @param encryptedData Encrypted contact information for recipient-issuer communication
     * @return integraHash The integraHash (echoed back)
     */
    function registerDocument(
        bytes32 integraHash,
        bytes32 documentHash,
        address resolver,
        bytes32 referencedDocument,
        uint256[2] calldata referenceProofA,
        uint256[2][2] calldata referenceProofB,
        uint256[2] calldata referenceProofC,
        string calldata encryptedData
    ) external nonReentrant whenNotPaused returns (bytes32) {
        return _registerDocument(
            msg.sender,
            integraHash,
            documentHash,
            resolver,
            referencedDocument,
            referenceProofA,
            referenceProofB,
            referenceProofC,
            encryptedData
        );
    }

    /**
     * @notice Register a new document (backend executor call)
     * @dev Executor specifies the document owner (backend pays gas, abstracts blockchain complexity)
     * @param owner The address that will own the document
     * @param integraHash Document identifier (generated off-chain by user)
     * @param documentHash Content hash of the document
     * @param resolver Approved tokenization resolver
     * @param referencedDocument Optional reference to parent document (requires zkProof)
     * @param referenceProofA ZK proof component A (required if referencedDocument != 0)
     * @param referenceProofB ZK proof component B (required if referencedDocument != 0)
     * @param referenceProofC ZK proof component C (required if referencedDocument != 0)
     * @param encryptedData Encrypted contact information for recipient-issuer communication
     * @return integraHash The integraHash (echoed back)
     */
    function registerDocumentFor(
        address owner,
        bytes32 integraHash,
        bytes32 documentHash,
        address resolver,
        bytes32 referencedDocument,
        uint256[2] calldata referenceProofA,
        uint256[2][2] calldata referenceProofB,
        uint256[2] calldata referenceProofC,
        string calldata encryptedData
    ) external nonReentrant whenNotPaused onlyRole(EXECUTOR_ROLE) returns (bytes32) {
        if (owner == address(0)) revert ZeroAddress();
        return _registerDocument(
            owner,
            integraHash,
            documentHash,
            resolver,
            referencedDocument,
            referenceProofA,
            referenceProofB,
            referenceProofC,
            encryptedData
        );
    }

    /**
     * @notice Internal document registration logic
     * @dev Shared by both direct and executor registration paths
     */
    function _registerDocument(
        address owner,
        bytes32 integraHash,
        bytes32 documentHash,
        address resolver,
        bytes32 referencedDocument,
        uint256[2] calldata referenceProofA,
        uint256[2][2] calldata referenceProofB,
        uint256[2] calldata referenceProofC,
        string calldata encryptedData
    ) internal returns (bytes32) {
        if (integraHash == bytes32(0)) {
            revert InvalidIntegraHash();
        }
        if (documentHash == bytes32(0)) {
            revert InvalidDocumentHash();
        }
        if (!approvedResolvers[resolver]) {
            revert ResolverNotApproved(resolver);
        }

        // Validate encrypted data length
        if (bytes(encryptedData).length > MAX_ENCRYPTED_DATA_LENGTH) {
            revert EncryptedDataTooLarge(bytes(encryptedData).length, MAX_ENCRYPTED_DATA_LENGTH);
        }

        // SECURITY: Verify zkProof for document references (anti-spam protection)
        if (referencedDocument != bytes32(0)) {
            // Get verifier from registry
            bytes32 verifierId = keccak256(abi.encodePacked("BasicAccessV1Poseidon", "v1"));
            address verifier = verifierRegistry.getVerifier(verifierId);
            if (verifier == address(0)) {
                revert VerifierNotFound();
            }

            // Verify proof of knowledge for referenced document
            // Note: Poseidon hash is a native field element - passed directly as uint256
            (bool success, bytes memory result) = verifier.staticcall(
                abi.encodeWithSignature(
                    "verifyProof(uint256[2],uint256[2][2],uint256[2],uint256)",
                    referenceProofA,
                    referenceProofB,
                    referenceProofC,
                    uint256(referencedDocument)
                )
            );

            if (!success || !abi.decode(result, (bool))) {
                revert InvalidProof(integraHash, owner);
            }

            // Verify referenced document exists
            if (!documents[referencedDocument].exists) {
                revert ReferenceDocumentNotFound(referencedDocument);
            }
        }

        if (documents[integraHash].exists) {
            revert DocumentAlreadyRegistered(integraHash, documents[integraHash].owner);
        }

        documents[integraHash] = DocumentRecord({
            owner: owner,
            documentHash: documentHash,
            resolver: resolver,
            referencedDocument: referencedDocument,
            encryptedData: encryptedData,
            registeredAt: block.timestamp,
            exists: true
        });

        emit DocumentRegistered(
            integraHash,
            documentHash,
            referencedDocument,
            owner,
            resolver,
            encryptedData,
            block.timestamp
        );

        if (referencedDocument != bytes32(0)) {
            emit DocumentReferenced(integraHash, referencedDocument, block.timestamp);
        }

        return integraHash;
    }

    /**
     * @notice Set resolver for a document (direct user call)
     */
    function setResolver(bytes32 integraHash, address newResolver) external nonReentrant whenNotPaused {
        _setResolver(msg.sender, integraHash, newResolver);
    }

    /**
     * @notice Set resolver for a document (backend executor call)
     */
    function setResolverFor(address owner, bytes32 integraHash, address newResolver)
        external nonReentrant whenNotPaused onlyRole(EXECUTOR_ROLE) {
        if (owner == address(0)) revert ZeroAddress();
        _setResolver(owner, integraHash, newResolver);
    }

    /**
     * @notice Internal resolver setting logic
     */
    function _setResolver(address caller, bytes32 integraHash, address newResolver) internal {
        DocumentRecord storage doc = documents[integraHash];

        if (!doc.exists) {
            revert DocumentNotRegistered(integraHash);
        }
        if (doc.owner != caller) {
            revert OnlyDocumentOwner(caller, doc.owner, integraHash);
        }
        if (!approvedResolvers[newResolver]) {
            revert ResolverNotApproved(newResolver);
        }

        address oldResolver = doc.resolver;
        doc.resolver = newResolver;

        emit ResolverSet(integraHash, oldResolver, newResolver, block.timestamp);
    }

    // ============ Ownership Management ============

    /**
     * @notice Transfer document ownership (direct user call)
     * @dev Current owner can transfer ownership to a new address
     * @param integraHash The document to transfer
     * @param newOwner The new owner address
     * @param reason Audit trail reason for transfer (e.g., "Company acquisition", "Key compromise")
     */
    function transferDocumentOwnership(
        bytes32 integraHash,
        address newOwner,
        string calldata reason
    ) external nonReentrant {
        _transferDocumentOwnership(msg.sender, integraHash, newOwner, reason);
    }

    /**
     * @notice Transfer document ownership (backend executor call)
     * @dev Executor can transfer on behalf of current owner (backend pays gas)
     */
    function transferDocumentOwnershipFor(
        address currentOwner,
        bytes32 integraHash,
        address newOwner,
        string calldata reason
    ) external nonReentrant onlyRole(EXECUTOR_ROLE) {
        if (currentOwner == address(0)) revert ZeroAddress();
        _transferDocumentOwnership(currentOwner, integraHash, newOwner, reason);
    }

    /**
     * @notice Internal ownership transfer logic
     */
    function _transferDocumentOwnership(
        address caller,
        bytes32 integraHash,
        address newOwner,
        string calldata reason
    ) internal {
        DocumentRecord storage doc = documents[integraHash];

        if (!doc.exists) {
            revert DocumentNotRegistered(integraHash);
        }
        if (doc.owner != caller) {
            revert OnlyOwnerCanTransfer(caller, doc.owner);
        }
        if (newOwner == address(0)) {
            revert InvalidNewOwner();
        }
        if (newOwner == doc.owner) {
            revert AlreadyTheOwner();
        }

        address oldOwner = doc.owner;
        doc.owner = newOwner;

        emit DocumentOwnershipTransferred(integraHash, oldOwner, newOwner, reason, block.timestamp);
    }

    // ============ Views ============

    function getDocument(bytes32 integraHash) external view returns (DocumentRecord memory) {
        return documents[integraHash];
    }

    function getResolver(bytes32 integraHash) external view returns (address) {
        return documents[integraHash].resolver;
    }

    function exists(bytes32 integraHash) external view returns (bool) {
        return documents[integraHash].exists;
    }

    /**
     * @notice Get document owner address
     * @dev More gas efficient than fetching full DocumentRecord when only owner is needed
     */
    function getDocumentOwner(bytes32 integraHash) external view returns (address) {
        return documents[integraHash].owner;
    }

    /**
     * @notice Check if an address is the document owner
     * @dev Useful for frontend authorization checks
     */
    function isDocumentOwner(bytes32 integraHash, address account) external view returns (bool) {
        return documents[integraHash].owner == account;
    }

    /**
     * @notice Batch query for multiple documents
     * @dev More efficient than multiple separate calls
     */
    function getDocumentsBatch(bytes32[] calldata integraHashes)
        external view returns (DocumentRecord[] memory) {
        DocumentRecord[] memory results = new DocumentRecord[](integraHashes.length);
        for (uint256 i = 0; i < integraHashes.length; i++) {
            results[i] = documents[integraHashes[i]];
        }
        return results;
    }

    /**
     * @notice Batch query for document existence
     * @dev Check multiple documents at once
     */
    function existsBatch(bytes32[] calldata integraHashes)
        external view returns (bool[] memory) {
        bool[] memory results = new bool[](integraHashes.length);
        for (uint256 i = 0; i < integraHashes.length; i++) {
            results[i] = documents[integraHashes[i]].exists;
        }
        return results;
    }

    /**
     * @notice Batch query for document owners
     * @dev Get owners for multiple documents at once
     */
    function getDocumentOwnersBatch(bytes32[] calldata integraHashes)
        external view returns (address[] memory) {
        address[] memory results = new address[](integraHashes.length);
        for (uint256 i = 0; i < integraHashes.length; i++) {
            results[i] = documents[integraHashes[i]].owner;
        }
        return results;
    }

    // ============ Admin ============

    function setResolverApproval(address resolver, bool approved) external onlyRole(GOVERNOR_ROLE) {
        approvedResolvers[resolver] = approved;
        emit ResolverApproved(resolver, approved, block.timestamp);
    }

    function setResolverApprovalBatch(
        address[] calldata resolvers,
        bool[] calldata approvals
    ) external onlyRole(GOVERNOR_ROLE) {
        require(resolvers.length == approvals.length, "Length mismatch");
        for (uint256 i = 0; i < resolvers.length; i++) {
            approvedResolvers[resolvers[i]] = approvals[i];
            emit ResolverApproved(resolvers[i], approvals[i], block.timestamp);
        }
    }

    function setVerifierRegistry(address _verifierRegistry) external onlyRole(GOVERNOR_ROLE) {
        if (_verifierRegistry == address(0)) {
            revert ZeroAddress();
        }
        verifierRegistry = IntegraVerifierRegistry(_verifierRegistry);
    }

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}
}
