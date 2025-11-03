// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/IDocumentResolver.sol";
import "../layer0/AttestationAccessControlV6.sol";

// TRUST GRAPH INTEGRATION
// Note: This import path assumes trust graph contracts will be deployed
// If PrivacyPreservingDocumentContract is not yet deployed, this can be added later
// import "../layer0-user-org-identity/trust-graph/contracts/PrivacyPreservingDocumentContract.sol";

/**
 * @title OwnershipResolver
 * @notice ERC-721 resolver for single-owner documents with trust graph integration
 *
 * V6 ARCHITECTURE:
 * - Anonymous reservations (address unknown at reservation time)
 * - Encrypted labels for document metadata
 * - Attestation-based access control (no ZK proofs)
 * - Simplified two-step workflow (reserve → claim)
 * - Trust credential issuance (when operations complete)
 *
 * USE CASES:
 * - Real estate deeds (single property owner)
 * - Vehicle titles (single vehicle owner)
 * - Copyright ownership (single copyright holder)
 * - Exclusive licenses (single licensee)
 *
 * CHARACTERISTICS:
 * - One NFT per document (exclusive ownership)
 * - Non-divisible (can't split ownership)
 * - Transferable (standard ERC-721 transfers)
 * - Unique tokenId per reservation
 *
 * WORKFLOW:
 * 1. Issuer reserves NFT with encrypted label (address unknown)
 * 2. Party verifies identity off-chain (email, DocuSign, etc.)
 * 3. Issuer issues capability attestation via EAS
 * 4. Party declares primary wallet (for trust accumulation)
 * 5. Party claims NFT using attestation (no ZK proof needed)
 * 6. When claimed: Trust credential issued to primary wallet
 *
 * TRUST INTEGRATION:
 * - Issues anonymous credentials when token is claimed
 * - Credentials accumulate at primary wallet level
 * - Builds ecosystem-wide trust scores
 * - Privacy-preserving (relationships hidden)
 */
contract OwnershipResolverV6 is
    ERC721Upgradeable,
    AttestationAccessControlV6,
    IDocumentResolver
    // PrivacyPreservingDocumentContract  // TODO: Uncomment when trust graph deployed
{
    // ============ Constants ============

    /**
     * @notice Maximum encrypted label length (500 bytes)
     * @dev Sized for encrypted role/party descriptions
     *      Sufficient for labels like "Series A Investor - 10% Equity - Board Observer"
     *      For larger metadata, use IPFS and store hash in label
     */
    uint256 public constant MAX_ENCRYPTED_LABEL_LENGTH = 500;
    uint256 public constant MAX_TOKENS_PER_DOCUMENT = 100;

    // ============ State Variables ============

    struct OwnershipTokenData {
        bytes32 integraHash;                          // Document identifier
        address owner;                                // Current owner (after minting)
        bool minted;                                  // Prevents double minting
        address reservedFor;                          // Specific address (or address(0) for anonymous)
        bytes encryptedLabel;                         // Document description encrypted with integraID
    }

    /// @notice Token data by tokenId
    mapping(uint256 => OwnershipTokenData) private tokenData;

    /// @notice Reverse mapping: integraHash → tokenId (one token per document)
    mapping(bytes32 => uint256) public integraHashToTokenId;

    /// @notice Monotonic counter for tokenId generation
    uint256 private _nextTokenId;

    /// @notice Base URI for token metadata
    string private _baseTokenURI;

    // ============ Trust Graph Integration ============

    /// @notice Track parties per document (for credential issuance)
    mapping(bytes32 => address[]) private documentParties;

    /// @notice Track if credentials have been issued
    mapping(bytes32 => bool) private credentialsIssued;

    /// @notice Ephemeral to primary wallet mapping (Layer 1 integration)
    // REMOVED: ephemeralToPrimary mapping - privacy flaw

    /// @notice Trust registry address (for credential issuance)
    /// @dev Set during initialization if trust graph is enabled
    address public trustRegistry;

    /// @notice Credential schema UID (for EAS registration)
    bytes32 public credentialSchema;

    // ============ Events ============

    // Additional events specific to OwnershipResolver
    event TokenMinted(
        bytes32 indexed integraHash,
        uint256 indexed tokenId,
        address indexed owner,
        uint256 timestamp
    );

    // Trust graph events

    event TrustCredentialsIssued(
        bytes32 indexed integraHash,
        uint256 partyCount,
        uint256 timestamp
    );

    // ============ Errors ============

    error AlreadyMinted(uint256 tokenId);
    error AlreadyReserved(bytes32 integraHash);
    error TokenNotFound(bytes32 integraHash, uint256 tokenId);
    error OnlyIssuerCanCancel(address caller, address issuer);
    error NotReservedForYou(address caller, address reservedFor);
    error ZeroAddress();
    error InvalidSignature();
    error TrustGraphNotEnabled();
    error EncryptedLabelTooLarge(uint256 length, uint256 maximum);

    // ============ Constructor & Initialization ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize contract
     * @param name_ ERC-721 token name
     * @param symbol_ ERC-721 token symbol
     * @param baseURI_ Base URI for token metadata
     * @param governor Governor address (admin role)
     * @param _eas EAS contract address
     * @param _accessCapabilitySchema Capability attestation schema UID
     * @param _credentialSchema Credential hash schema UID (for trust graph)
     * @param _trustRegistry Trust registry address (address(0) to disable trust graph)
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        string memory baseURI_,
        address governor,
        address _eas,
        bytes32 _accessCapabilitySchema,
        bytes32 _credentialSchema,
        address _trustRegistry
    ) external initializer {
        if (governor == address(0)) revert ZeroAddress();

        __ERC721_init(name_, symbol_);
        __ReentrancyGuard_init();
        __AttestationAccessControl_init(_eas, _accessCapabilitySchema);  // Calls __UUPSUpgradeable_init and __AccessControl_init internally

        _baseTokenURI = baseURI_;
        _nextTokenId = 1;

        // Trust graph integration (optional - can be disabled by passing address(0))
        credentialSchema = _credentialSchema;
        trustRegistry = _trustRegistry;

        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
        _grantRole(EXECUTOR_ROLE, governor);
        _grantRole(OPERATOR_ROLE, governor);
    }

    // ============ Emergency Controls ============

    /**
     * @notice Pause all token operations (emergency use only)
     * @dev Pauses claimToken, reserveToken, reserveTokenAnonymous, cancelReservation
     *      Admin functions remain active for emergency response
     */
    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause token operations
     */
    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // ============ IDocumentResolver Implementation ============

    /**
     * @notice Reserve NFT for specific address
     * @dev Use when recipient address is known upfront
     */
    function reserveToken(
        address caller,
        bytes32 integraHash,
        uint256 tokenId,
        address recipient,
        uint256 amount
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant whenNotPaused {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 existingTokenId = integraHashToTokenId[integraHash];
        if (existingTokenId != 0) {
            OwnershipTokenData storage existing = tokenData[existingTokenId];
            if (existing.minted) {
                revert AlreadyMinted(existingTokenId);
            }
            if (existing.reservedFor != address(0)) {
                revert AlreadyReserved(integraHash);
            }
        }

        uint256 newTokenId = _nextTokenId++;

        tokenData[newTokenId] = OwnershipTokenData({
            integraHash: integraHash,
            owner: address(0),
            minted: false,
            reservedFor: recipient,
            encryptedLabel: ""
        });

        integraHashToTokenId[integraHash] = newTokenId;

        emit IDocumentResolver.TokenReserved(integraHash, newTokenId, recipient, 1, block.timestamp);
    }

    /**
     * @notice Reserve NFT anonymously (address unknown)
     * @dev Use when recipient address is unknown at reservation time
     *      This is the PRIMARY function for Integra's use case
     */
    function reserveTokenAnonymous(
        address caller,
        bytes32 integraHash,
        uint256 tokenId,
        uint256 amount,
        bytes calldata encryptedLabel
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant whenNotPaused {
        // Validate encrypted label length
        if (encryptedLabel.length > MAX_ENCRYPTED_LABEL_LENGTH) {
            revert EncryptedLabelTooLarge(encryptedLabel.length, MAX_ENCRYPTED_LABEL_LENGTH);
        }

        uint256 existingTokenId = integraHashToTokenId[integraHash];
        if (existingTokenId != 0) {
            revert AlreadyReserved(integraHash);
        }

        uint256 newTokenId = _nextTokenId++;

        tokenData[newTokenId] = OwnershipTokenData({
            integraHash: integraHash,
            owner: address(0),
            minted: false,
            reservedFor: address(0),  // Anonymous - address unknown
            encryptedLabel: encryptedLabel
        });

        integraHashToTokenId[integraHash] = newTokenId;

        emit IDocumentResolver.TokenReservedAnonymous(integraHash, newTokenId, 1, encryptedLabel, block.timestamp);
    }

    /**
     * @notice Claim reserved NFT with attestation
     * @param integraHash Document identifier
     * @param tokenId Token ID to claim (optional - can be 0 to auto-detect)
     * @param capabilityAttestationUID EAS attestation proving claim capability
     *
     * @dev Simplified workflow - attestation IS the approval
     *      No separate request/approve steps needed
     *      No ZK proof required - attestation provides access control
     *
     * ACCESS CONTROL:
     * - Requires valid capability attestation from document issuer
     * - Attestation must grant CAPABILITY_CLAIM_TOKEN
     * - Attestation must not be revoked or expired
     * - For address-specific reservations, must match reservedFor
     * - For anonymous reservations, any valid attestation can claim
     *
     * TRUST INTEGRATION:
     * - Tracks party for credential issuance
     * - Issues trust credential to primary wallet when token claimed
     * - Credential proves business transaction completion
     * - Trust score improves from successful operations
     */
    function claimToken(
        bytes32 integraHash,
        uint256 tokenId,
        bytes32 capabilityAttestationUID
    )
        external
        requiresCapability(integraHash, CAPABILITY_CLAIM_TOKEN, capabilityAttestationUID)
        nonReentrant
        whenNotPaused
    {
        // Auto-detect tokenId if not provided
        uint256 actualTokenId = tokenId != 0 ? tokenId : integraHashToTokenId[integraHash];

        if (actualTokenId == 0) {
            revert TokenNotFound(integraHash, tokenId);
        }

        OwnershipTokenData storage data = tokenData[actualTokenId];

        // Verify not already minted
        if (data.minted) {
            revert AlreadyMinted(actualTokenId);
        }

        // If reserved for specific address, verify caller matches
        if (data.reservedFor != address(0) && data.reservedFor != msg.sender) {
            revert NotReservedForYou(msg.sender, data.reservedFor);
        }

        // Mint NFT to claimer
        _safeMint(msg.sender, actualTokenId);

        // Update state
        data.owner = msg.sender;
        data.minted = true;
        data.reservedFor = address(0);

        emit IDocumentResolver.TokenClaimed(integraHash, actualTokenId, msg.sender, capabilityAttestationUID, block.timestamp);
        emit TokenMinted(integraHash, actualTokenId, msg.sender, block.timestamp);

        // TRUST GRAPH: Track party and issue credential if enabled
        _handleTrustCredential(integraHash, msg.sender);
    }

    /**
     * @notice Cancel reservation (issuer only)
     * @param caller Caller address
     * @param integraHash Document identifier
     * @param tokenId Token ID (optional - can be 0 to auto-detect)
     *
     * @dev Only document issuer can cancel reservations
     */
    function cancelReservation(
        address caller,
        bytes32 integraHash,
        uint256 tokenId
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant whenNotPaused {
        // Verify caller is document issuer
        address issuer = documentIssuers[integraHash];
        if (caller != issuer) {
            revert OnlyIssuerCanCancel(caller, issuer);
        }

        uint256 actualTokenId = tokenId != 0 ? tokenId : integraHashToTokenId[integraHash];

        if (actualTokenId == 0) {
            revert TokenNotFound(integraHash, tokenId);
        }

        OwnershipTokenData storage data = tokenData[actualTokenId];

        if (data.minted) {
            revert AlreadyMinted(actualTokenId);
        }

        // Clear reservation
        delete tokenData[actualTokenId];
        delete integraHashToTokenId[integraHash];

        emit IDocumentResolver.ReservationCancelled(integraHash, actualTokenId, 1, block.timestamp);
    }

    // ============ View Functions ============

    /**
     * @notice Get token balance (ERC-721 standard)
     * @param account Address to query
     * @param tokenId Token ID (or 0 for total balance)
     */
    function balanceOf(
        address account,
        uint256 tokenId
    ) public view returns (uint256) {
        if (tokenId == 0) {
            return ERC721Upgradeable.balanceOf(account);
        } else {
            // Check if token exists by looking at our tokenData
            if (tokenData[tokenId].integraHash == bytes32(0)) {
                return 0; // Token doesn't exist
            }
            // If token is minted, check ownership
            if (tokenData[tokenId].minted) {
                return _ownerOf(tokenId) == account ? 1 : 0;
            }
            return 0; // Token exists but not yet minted
        }
    }

    /**
     * @notice Get comprehensive token information
     */
    function getTokenInfo(
        bytes32 integraHash,
        uint256 tokenId
    ) external view returns (IDocumentResolver.TokenInfo memory) {
        uint256 actualTokenId = tokenId != 0 ? tokenId : integraHashToTokenId[integraHash];

        if (actualTokenId == 0) {
            return IDocumentResolver.TokenInfo({
                integraHash: integraHash,
                tokenId: 0,
                totalSupply: 0,
                reserved: 0,
                holders: new address[](0),
                encryptedLabel: "",
                reservedFor: address(0),
                claimed: false,
                claimedBy: address(0)
            });
        }

        OwnershipTokenData storage data = tokenData[actualTokenId];

        address[] memory holders = new address[](data.minted ? 1 : 0);
        if (data.minted) {
            holders[0] = data.owner;
        }

        return IDocumentResolver.TokenInfo({
            integraHash: integraHash,
            tokenId: actualTokenId,
            totalSupply: data.minted ? 1 : 0,
            reserved: data.reservedFor != address(0) || !data.minted ? 1 : 0,
            holders: holders,
            encryptedLabel: data.encryptedLabel,
            reservedFor: data.reservedFor,
            claimed: data.minted,
            claimedBy: data.owner
        });
    }

    /**
     * @notice Get encrypted label for NFT
     */
    function getEncryptedLabel(
        bytes32 integraHash,
        uint256 tokenId
    ) external view returns (bytes memory) {
        uint256 actualTokenId = tokenId != 0 ? tokenId : integraHashToTokenId[integraHash];
        return tokenData[actualTokenId].encryptedLabel;
    }

    /**
     * @notice Get all encrypted labels for document
     * @dev OwnershipResolver only has one token per document
     */
    function getAllEncryptedLabels(bytes32 integraHash)
        external
        view
        returns (uint256[] memory tokenIds, bytes[] memory labels)
    {
        uint256 tokenId = integraHashToTokenId[integraHash];

        if (tokenId == 0) {
            return (new uint256[](0), new bytes[](0));
        }

        tokenIds = new uint256[](1);
        labels = new bytes[](1);

        tokenIds[0] = tokenId;
        labels[0] = tokenData[tokenId].encryptedLabel;

        return (tokenIds, labels);
    }

    /**
     * @notice Get reserved tokens for address
     * @dev Returns empty array for anonymous reservations
     */
    function getReservedTokens(
        bytes32 integraHash,
        address recipient
    ) external view returns (uint256[] memory) {
        uint256 tokenId = integraHashToTokenId[integraHash];

        if (tokenId == 0) {
            return new uint256[](0);
        }

        OwnershipTokenData storage data = tokenData[tokenId];

        // Check if reserved for this recipient
        if (data.reservedFor == recipient && !data.minted) {
            uint256[] memory result = new uint256[](1);
            result[0] = tokenId;
            return result;
        }

        return new uint256[](0);
    }

    /**
     * @notice Get claim status for token
     */
    function getClaimStatus(bytes32 integraHash, uint256 tokenId)
        external
        view
        returns (bool claimed, address claimedBy)
    {
        uint256 actualTokenId = tokenId != 0 ? tokenId : integraHashToTokenId[integraHash];

        if (actualTokenId == 0) {
            return (false, address(0));
        }

        OwnershipTokenData storage data = tokenData[actualTokenId];
        return (data.minted, data.owner);
    }

    /**
     * @notice Get token type
     */
    function tokenType() external pure returns (IDocumentResolver.TokenType) {
        return IDocumentResolver.TokenType.ERC721;
    }

    // ============ ERC-721 Overrides ============

    /**
     * @notice Get base URI for token metadata
     */
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /**
     * @notice Set base URI
     * @param baseURI_ New base URI
     */
    function setBaseURI(string memory baseURI_) external onlyRole(GOVERNOR_ROLE) {
        _baseTokenURI = baseURI_;
    }

    // ============ Admin Functions ============

    /**
     * @notice Authorize contract upgrade
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(GOVERNOR_ROLE)
    {}

    /**
     * @notice Check interface support
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721Upgradeable, AccessControlUpgradeable) returns (bool) {
        return
            interfaceId == type(IDocumentResolver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ============ Trust Graph Integration ============

    /**
     * @notice Declare primary wallet for ephemeral address (Layer 1 integration)
     * @param primary Primary wallet address (where trust accumulates)
     * @param signature Signature from primary authorizing this ephemeral
     * @dev Enables trust credential accumulation at primary wallet level
     *      Call this before claiming token to ensure credentials go to primary
     */

    /**
     * @notice Handle trust credential issuance after token claim
     * @param integraHash Document identifier
     * @param party Address that claimed (could be ephemeral)
     * @dev Issues credential to primary wallet via EAS
     */
    function _handleTrustCredential(bytes32 integraHash, address party) internal {
        // Skip if trust graph not enabled
        if (trustRegistry == address(0)) return;

        // Skip if already issued
        if (credentialsIssued[integraHash]) return;

        // Track party
        if (!_isPartyTracked(integraHash, party)) {
            documentParties[integraHash].push(party);
        }

        // For OwnershipResolver: Document complete when NFT is minted
        // Issue credential immediately
        _issueCredentialsToAllParties(integraHash);
    }

    /**
     * @notice Issue trust credentials to all document parties
     * @param integraHash Document identifier
     * @dev Issues anonymous credentials to primary wallets via EAS
     */
    function _issueCredentialsToAllParties(bytes32 integraHash) internal {
        address[] memory parties = documentParties[integraHash];

        for (uint i = 0; i < parties.length; i++) {
            _issueCredentialToParty(parties[i], integraHash);
        }

        credentialsIssued[integraHash] = true;

        emit TrustCredentialsIssued(integraHash, parties.length, block.timestamp);
    }

    /**
     * @notice Issue credential to a single party
     * @param party Party address (could be ephemeral)
     * @param integraHash Document identifier
     * @dev Simplified credential issuance - registers hash on EAS
     *      Full implementation would use PrivacyPreservingDocumentContract
     */
    function _issueCredentialToParty(address party, bytes32 integraHash) internal {
        // Get primary wallet (trust accumulates here)
        address recipient = party;  // Issue to ephemeral directly; indexer attributes to primary off-chain

        // Generate credential hash (simplified - actual would have commitments)
        bytes32 credentialHash = keccak256(abi.encode(
            integraHash,
            recipient,
            block.timestamp,
            block.chainid
        ));

        // Register credential hash on EAS
        // Note: This is simplified. Full implementation from PrivacyPreservingDocumentContract
        // would include counterparty commitments, Poseidon hashing, etc.
        if (credentialSchema != bytes32(0)) {
            try eas.attest(
                IEAS.AttestationRequest({
                    schema: credentialSchema,
                    data: IEAS.AttestationRequestData({
                        recipient: recipient,  // PRIMARY wallet
                        expirationTime: uint64(block.timestamp + 180 days),
                        revocable: true,
                        refUID: bytes32(0),
                        data: abi.encode(credentialHash),
                        value: 0
                    })
                })
            ) {
                // Credential registered successfully
            } catch {
                // Credential issuance failed - continue anyway
                // Don't block token claiming if credential fails
            }
        }
    }

    /**
     * @notice Check if party is already tracked
     */
    function _isPartyTracked(bytes32 integraHash, address party) internal view returns (bool) {
        address[] memory parties = documentParties[integraHash];
        for (uint i = 0; i < parties.length; i++) {
            if (parties[i] == party) return true;
        }
        return false;
    }

    // ============ Storage Gap ============

    /**
     * @dev Storage gap for future upgrades
     * Gap calculation: 50 - 9 state variables = 41 slots
     * Original: tokenData (1), integraHashToTokenId (1), _nextTokenId (1), _baseTokenURI (1) = 4
     * Trust graph: documentParties (1), credentialsIssued (1), ephemeralToPrimary (1),
     *             trustRegistry (1), credentialSchema (1) = 5
     * Total: 9 variables = 41 gap slots
     */
    uint256[41] private __gap;
}
