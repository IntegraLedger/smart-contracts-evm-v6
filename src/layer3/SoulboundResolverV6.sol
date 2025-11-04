// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/IDocumentResolver.sol";
import "../layer0/AttestationAccessControlV6.sol";

/**
 * @title SoulboundResolverV6
 * @notice ERC-5192 resolver for non-transferable credentials with trust graph integration
 *
 * V6 ARCHITECTURE:
 * - Anonymous reservations (address unknown at reservation time)
 * - Encrypted labels for credential metadata
 * - Attestation-based access control (no ZK proofs)
 * - Simplified two-step workflow (reserve → claim)
 * - Permanent binding (non-transferable after minting)
 *
 * USE CASES:
 * - Professional licenses (medical, legal, contractor certifications)
 * - Educational credentials (diplomas, training certificates)
 * - Identity documents (residency proof, age verification)
 * - Compliance certifications (KYC/AML badges, accredited investor status)
 * - Achievement badges (non-revocable awards)
 *
 * CHARACTERISTICS:
 * - One NFT per credential (unique per recipient)
 * - Non-transferable (permanently bound to claimer)
 * - Locked state (ERC-5192 compliance)
 * - Optional expiration (time-limited credentials)
 *
 * WORKFLOW:
 * 1. Issuer reserves credential with encrypted label (address unknown)
 * 2. Recipient verifies identity off-chain (email, video call, document submission)
 * 3. Issuer issues capability attestation via EAS
 * 4. Recipient claims credential (token minted and locked)
 * 5. Token permanently bound to recipient (cannot be transferred)
 * 6. Trust credential issued to primary wallet
 *
 * ERC-5192 COMPLIANCE:
 * - Implements locked() function (always returns true after mint)
 * - All transfer functions revert for locked tokens
 * - Emits Locked event on minting
 */
contract SoulboundResolverV6 is
    ERC721Upgradeable,
    AttestationAccessControlV6,
    IDocumentResolver
{
    // ============ Constants ============

    /**
     * @notice Maximum encrypted label length (500 bytes)
     * @dev Sized for encrypted credential descriptions
     */
    uint256 public constant MAX_ENCRYPTED_LABEL_LENGTH = 500;
    uint256 public constant MAX_TOKENS_PER_DOCUMENT = 100;

    // ============ ERC-5192 Interface ID ============

    bytes4 private constant _INTERFACE_ID_ERC5192 = 0xb45a3c0e;

    // ============ State Variables ============

    struct SoulboundTokenData {
        bytes32 integraHash;                          // Document identifier
        address owner;                                // Bound to this address
        bool minted;                                  // Prevents double minting
        bool locked;                                  // Transfer lock status (always true)
        address reservedFor;                          // Specific address (or address(0) for anonymous)
        bytes encryptedLabel;                         // Credential description
        uint256 issuanceDate;                         // When token was claimed
        uint256 expirationDate;                       // Optional expiration (0 = no expiry)
    }

    /// @notice Token data by tokenId
    mapping(uint256 => SoulboundTokenData) private tokenData;

    /// @notice Reverse mapping: integraHash → tokenId
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

    /// @notice Trust registry address (for credential issuance)
    address public trustRegistry;

    /// @notice Credential schema UID (for EAS registration)
    bytes32 public credentialSchema;

    // ============ Events ============

    // ERC-5192 events
    event Locked(uint256 indexed tokenId);
    // Note: Unlocked event removed - tokens are permanently locked (no unlock mechanism)

    // Additional events
    event TokenMinted(
        bytes32 indexed integraHash,
        uint256 indexed tokenId,
        address indexed owner,
        uint256 timestamp
    );

    event TrustCredentialsIssued(
        bytes32 indexed integraHash,
        uint256 partyCount,
        uint256 timestamp
    );

    event CredentialExpired(
        bytes32 indexed integraHash,
        uint256 indexed tokenId,
        uint256 timestamp
    );

    // ============ Errors ============

    error AlreadyMinted(uint256 tokenId);
    error AlreadyReserved(bytes32 integraHash);
    error TokenNotFound(bytes32 integraHash, uint256 tokenId);
    error OnlyIssuerCanCancel(address caller, address issuer);
    error NotReservedForYou(address caller, address reservedFor);
    error ZeroAddress();
    error TokenIsLocked(uint256 tokenId);
    error EncryptedLabelTooLarge(uint256 length, uint256 maximum);
    error CannotUnlockToken(uint256 tokenId);

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
        __AttestationAccessControl_init(_eas, _accessCapabilitySchema);

        _baseTokenURI = baseURI_;
        _nextTokenId = 1;

        // Trust graph integration
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
     * @notice Reserve soulbound token for specific address
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
            revert AlreadyReserved(integraHash);
        }

        uint256 newTokenId = _nextTokenId++;

        tokenData[newTokenId] = SoulboundTokenData({
            integraHash: integraHash,
            owner: address(0),
            minted: false,
            locked: false,
            reservedFor: recipient,
            encryptedLabel: "",
            issuanceDate: 0,
            expirationDate: 0
        });

        integraHashToTokenId[integraHash] = newTokenId;

        emit IDocumentResolver.TokenReserved(integraHash, newTokenId, recipient, 1, block.timestamp);
    }

    /**
     * @notice Reserve soulbound token anonymously (address unknown)
     * @dev PRIMARY function for Integra's credential use case
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

        tokenData[newTokenId] = SoulboundTokenData({
            integraHash: integraHash,
            owner: address(0),
            minted: false,
            locked: false,
            reservedFor: address(0),  // Anonymous
            encryptedLabel: encryptedLabel,
            issuanceDate: 0,
            expirationDate: 0
        });

        integraHashToTokenId[integraHash] = newTokenId;

        emit IDocumentResolver.TokenReservedAnonymous(integraHash, newTokenId, 1, encryptedLabel, block.timestamp);
    }

    /**
     * @notice Claim soulbound credential with attestation
     * @param integraHash Document identifier
     * @param tokenId Token ID to claim (optional - can be 0 to auto-detect)
     * @param capabilityAttestationUID EAS attestation proving claim capability
     *
     * @dev Token is minted and immediately locked (non-transferable)
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

        SoulboundTokenData storage data = tokenData[actualTokenId];

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
        data.locked = true;  // Lock immediately (soulbound)
        data.reservedFor = address(0);
        data.issuanceDate = block.timestamp;

        emit IDocumentResolver.TokenClaimed(integraHash, actualTokenId, msg.sender, capabilityAttestationUID, block.timestamp);
        emit TokenMinted(integraHash, actualTokenId, msg.sender, block.timestamp);
        emit Locked(actualTokenId);  // ERC-5192 event

        // TRUST GRAPH: Track party and issue credential
        _handleTrustCredential(integraHash, msg.sender);
    }

    /**
     * @notice Cancel reservation (issuer only)
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

        SoulboundTokenData storage data = tokenData[actualTokenId];

        if (data.minted) {
            revert AlreadyMinted(actualTokenId);
        }

        // Clear reservation
        delete tokenData[actualTokenId];
        delete integraHashToTokenId[integraHash];

        emit IDocumentResolver.ReservationCancelled(integraHash, actualTokenId, 1, block.timestamp);
    }

    // ============ ERC-5192 Interface ============

    /**
     * @notice Check if token is locked (non-transferable)
     * @param tokenId Token ID to check
     * @return True if locked (always true for minted soulbound tokens)
     */
    function locked(uint256 tokenId) external view returns (bool) {
        return tokenData[tokenId].locked;
    }

    // ============ Transfer Overrides (ERC-5192 Compliance) ============

    /**
     * @notice Override transfer to enforce soulbound (locked) behavior
     * @dev Reverts if token is locked
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);

        // Allow minting (from == address(0))
        // Allow burning (to == address(0)) by GOVERNOR only
        // Block all other transfers if locked
        if (from != address(0) && to != address(0) && tokenData[tokenId].locked) {
            revert TokenIsLocked(tokenId);
        }

        return super._update(to, tokenId, auth);
    }

    /**
     * @notice Emergency unlock removed - tokens are permanently soulbound
     * @dev For credential reissuance, revoke old credential and issue new one
     *      True soulbound tokens should never be unlocked per ERC-5192 spirit
     */

    // ============ View Functions ============

    /**
     * @notice Get token balance (ERC-721 standard)
     */
    function balanceOf(
        address account,
        uint256 tokenId
    ) public view returns (uint256) {
        if (tokenId == 0) {
            return ERC721Upgradeable.balanceOf(account);
        } else {
            if (tokenData[tokenId].integraHash == bytes32(0)) {
                return 0;
            }
            if (tokenData[tokenId].minted) {
                return _ownerOf(tokenId) == account ? 1 : 0;
            }
            return 0;
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

        SoulboundTokenData storage data = tokenData[actualTokenId];

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
     * @notice Get encrypted label for credential
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
     */
    function getReservedTokens(
        bytes32 integraHash,
        address recipient
    ) external view returns (uint256[] memory) {
        uint256 tokenId = integraHashToTokenId[integraHash];

        if (tokenId == 0) {
            return new uint256[](0);
        }

        SoulboundTokenData storage data = tokenData[tokenId];

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

        SoulboundTokenData storage data = tokenData[actualTokenId];
        return (data.minted, data.owner);
    }

    /**
     * @notice Get token type
     */
    function tokenType() external pure returns (IDocumentResolver.TokenType) {
        return IDocumentResolver.TokenType.ERC721;
    }

    /**
     * @notice Check if credential is expired
     * @param tokenId Token ID to check
     * @return True if expired (expirationDate set and passed)
     */
    function isExpired(uint256 tokenId) public view returns (bool) {
        SoulboundTokenData storage data = tokenData[tokenId];
        if (data.expirationDate == 0) return false;  // No expiration
        return block.timestamp > data.expirationDate;
    }

    /**
     * @notice Get credential expiration date
     * @param tokenId Token ID to check
     * @return Expiration timestamp (0 = no expiration)
     */
    function expirationDate(uint256 tokenId) external view returns (uint256) {
        return tokenData[tokenId].expirationDate;
    }

    /**
     * @notice Set expiration date for credential (issuer only)
     * @param integraHash Document identifier
     * @param expiration Expiration timestamp
     */
    function setExpirationDate(
        bytes32 integraHash,
        uint256 expiration
    ) external onlyRole(OPERATOR_ROLE) {
        uint256 tokenId = integraHashToTokenId[integraHash];
        if (tokenId == 0) revert TokenNotFound(integraHash, 0);

        tokenData[tokenId].expirationDate = expiration;

        if (expiration > 0 && block.timestamp > expiration) {
            emit CredentialExpired(integraHash, tokenId, block.timestamp);
        }
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
            interfaceId == _INTERFACE_ID_ERC5192 ||
            super.supportsInterface(interfaceId);
    }

    // ============ Trust Graph Integration ============

    /**
     * @notice Handle trust credential issuance after token claim
     */
    function _handleTrustCredential(bytes32 integraHash, address party) internal {
        if (trustRegistry == address(0)) return;
        if (credentialsIssued[integraHash]) return;

        // Track party
        if (!_isPartyTracked(integraHash, party)) {
            documentParties[integraHash].push(party);
        }

        // For SoulboundResolver: Credential issued immediately when claimed
        _issueCredentialsToAllParties(integraHash);
    }

    /**
     * @notice Issue trust credentials to all document parties
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
     */
    function _issueCredentialToParty(address party, bytes32 integraHash) internal {
        address recipient = party;

        bytes32 credentialHash = keccak256(abi.encode(
            integraHash,
            recipient,
            block.timestamp,
            block.chainid
        ));

        if (credentialSchema != bytes32(0)) {
            try eas.attest(
                IEAS.AttestationRequest({
                    schema: credentialSchema,
                    data: IEAS.AttestationRequestData({
                        recipient: recipient,
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
     * Gap calculation: 50 - 10 state variables = 40 slots
     * Increased to 50 slots for additional safety margin
     */
    uint256[50] private __gap;
}
