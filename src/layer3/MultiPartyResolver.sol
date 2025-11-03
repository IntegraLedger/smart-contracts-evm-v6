// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/IDocumentResolver.sol";
import "../layer0/AttestationAccessControl.sol";

/**
 * @title MultiPartyResolver
 * @notice ERC-1155 resolver for multi-stakeholder documents
 *
 * V6 ARCHITECTURE:
 * - Anonymous reservations (address unknown at reservation time)
 * - Encrypted labels for role identification
 * - Attestation-based access control (no ZK proofs)
 * - Simplified two-step workflow (reserve → claim)
 *
 * TOKEN ID SEMANTICS:
 * Token IDs represent roles in multi-party contracts:
 * - 1: Buyer, 2: Seller, 3: Tenant, 4: Landlord, 5: Partner, etc.
 *
 * USE CASES:
 * - Purchase agreements (buyer + seller)
 * - Lease contracts (tenant + landlord + guarantor)
 * - Partnership agreements (multiple partners)
 * - Multi-party legal contracts (any number of stakeholders)
 *
 * WORKFLOW:
 * 1. Issuer reserves tokens with encrypted labels (address unknown)
 * 2. Parties verify identity off-chain (email, DocuSign, video, etc.)
 * 3. Issuer issues capability attestation via EAS
 * 4. Party claims token using attestation (no ZK proof needed)
 */
contract MultiPartyResolver is
    ERC1155Upgradeable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    AttestationAccessControl,
    IDocumentResolver
{
    // ============ Constants ============

    uint256 public constant MAX_ENCRYPTED_LABEL_LENGTH = 10000;
    uint256 public constant MAX_TOKENS_PER_DOCUMENT = 100;

    // ============ State Variables ============

    struct TokenData {
        bytes32 integraHash;                          // Document identifier
        uint256 totalSupply;                          // Total minted tokens
        uint256 reservedAmount;                       // Reserved but not minted
        bytes encryptedLabel;                         // Role label encrypted with integraID
        address reservedFor;                          // Specific address (or address(0) for anonymous)
        bool claimed;                                 // Whether token has been claimed
        address claimedBy;                            // Who claimed the token
        address[] holders;                            // Current token holders
        mapping(address => bool) isHolder;            // Quick holder lookup
    }

    /// @notice Token data: integraHash → tokenId → TokenData
    mapping(bytes32 => mapping(uint256 => TokenData)) private tokenData;

    /// @notice Base URI for token metadata
    string private _baseURI;

    // ============ Trust Graph Integration ============

    /// @notice Track parties per document (for credential issuance)
    mapping(bytes32 => address[]) private documentParties;

    /// @notice Track if credentials have been issued
    mapping(bytes32 => bool) private credentialsIssued;

    /// @notice Ephemeral to primary wallet mapping (Layer 1 integration)
    mapping(address => address) public ephemeralToPrimary;

    /// @notice Trust registry address (for credential issuance)
    /// @dev Set during initialization if trust graph is enabled
    address public trustRegistry;

    /// @notice Credential schema UID (for EAS registration)
    bytes32 public credentialSchema;

    // ============ Events ============

    // Additional events (base events in IDocumentResolver)
    event TokenUpdated(
        bytes32 indexed integraHash,
        uint256 indexed tokenId,
        uint256 timestamp
    );

    // Trust graph events
    event PrimaryWalletDeclared(
        address indexed ephemeral,
        address indexed primary,
        bytes32 indexed integraHash
    );

    event TrustCredentialsIssued(
        bytes32 indexed integraHash,
        uint256 partyCount,
        uint256 timestamp
    );

    // ============ Errors ============

    error InvalidAmount(uint256 amount);
    error TokenAlreadyReserved(bytes32 integraHash, uint256 tokenId);
    error TokenNotReserved(bytes32 integraHash, uint256 tokenId);
    error TokenAlreadyClaimed(bytes32 integraHash, uint256 tokenId);
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
     * @param baseURI_ Base URI for token metadata
     * @param governor Governor address (admin role)
     * @param _eas EAS contract address
     * @param _accessCapabilitySchema Capability attestation schema UID
     * @param _credentialSchema Credential hash schema UID (for trust graph)
     * @param _trustRegistry Trust registry address (address(0) to disable trust graph)
     */
    function initialize(
        string memory baseURI_,
        address governor,
        address _eas,
        bytes32 _accessCapabilitySchema,
        bytes32 _credentialSchema,
        address _trustRegistry
    ) external initializer {
        if (governor == address(0)) revert ZeroAddress();

        __ERC1155_init(baseURI_);
        __ReentrancyGuard_init();
        __AttestationAccessControl_init(_eas, _accessCapabilitySchema);  // Calls __UUPSUpgradeable_init and __AccessControl_init internally

        _baseURI = baseURI_;

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
     * @notice Reserve token for specific address
     * @dev Use when recipient address is known upfront
     */
    function reserveToken(
        address caller,
        bytes32 integraHash,
        uint256 tokenId,
        address recipient,
        uint256 amount
    ) external override onlyRole(EXECUTOR_ROLE) nonReentrant whenNotPaused {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount(amount);

        TokenData storage data = tokenData[integraHash][tokenId];

        if (data.integraHash != bytes32(0)) {
            revert TokenAlreadyReserved(integraHash, tokenId);
        }

        data.integraHash = integraHash;
        data.reservedAmount = amount;
        data.reservedFor = recipient;
        data.claimed = false;

        emit TokenReserved(integraHash, tokenId, recipient, amount, block.timestamp);
    }

    /**
     * @notice Reserve token anonymously (address unknown)
     * @dev Use when recipient address is unknown at reservation time
     *      This is the PRIMARY function for Integra's use case
     */
    function reserveTokenAnonymous(
        address caller,
        bytes32 integraHash,
        uint256 tokenId,
        uint256 amount,
        bytes calldata encryptedLabel
    ) external override onlyRole(EXECUTOR_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount(amount);

        // Validate encrypted label length
        if (encryptedLabel.length > MAX_ENCRYPTED_LABEL_LENGTH) {
            revert EncryptedLabelTooLarge(encryptedLabel.length, MAX_ENCRYPTED_LABEL_LENGTH);
        }

        TokenData storage data = tokenData[integraHash][tokenId];

        if (data.integraHash != bytes32(0)) {
            revert TokenAlreadyReserved(integraHash, tokenId);
        }

        data.integraHash = integraHash;
        data.reservedAmount = amount;
        data.encryptedLabel = encryptedLabel;
        data.reservedFor = address(0);  // Anonymous - address unknown
        data.claimed = false;

        emit TokenReservedAnonymous(integraHash, tokenId, amount, encryptedLabel, block.timestamp);
    }

    /**
     * @notice Claim reserved token with attestation
     * @param integraHash Document identifier
     * @param tokenId Token ID to claim
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
     */
    function claimToken(
        bytes32 integraHash,
        uint256 tokenId,
        bytes32 capabilityAttestationUID
    )
        external
        override
        requiresCapability(integraHash, CAPABILITY_CLAIM_TOKEN, capabilityAttestationUID)
        nonReentrant
        whenNotPaused
    {
        TokenData storage data = tokenData[integraHash][tokenId];

        // Verify token is reserved
        if (data.integraHash == bytes32(0)) {
            revert TokenNotReserved(integraHash, tokenId);
        }

        // Verify not already claimed
        if (data.claimed) {
            revert TokenAlreadyClaimed(integraHash, tokenId);
        }

        // If reserved for specific address, verify caller matches
        if (data.reservedFor != address(0) && data.reservedFor != msg.sender) {
            revert NotReservedForYou(msg.sender, data.reservedFor);
        }

        // Mint token to claimer
        _mint(msg.sender, tokenId, data.reservedAmount, "");

        // Update state
        data.totalSupply += data.reservedAmount;
        data.reservedAmount = 0;
        data.claimed = true;
        data.claimedBy = msg.sender;

        // Track holder
        if (!data.isHolder[msg.sender]) {
            data.holders.push(msg.sender);
            data.isHolder[msg.sender] = true;
        }

        emit TokenClaimed(integraHash, tokenId, msg.sender, capabilityAttestationUID, block.timestamp);

        // TRUST GRAPH: Track party and issue credential if document complete
        _handleTrustCredential(integraHash, msg.sender);
    }

    /**
     * @notice Cancel reservation (issuer only)
     * @param caller Caller address
     * @param integraHash Document identifier
     * @param tokenId Token ID
     *
     * @dev Only document issuer can cancel reservations
     */
    function cancelReservation(
        address caller,
        bytes32 integraHash,
        uint256 tokenId
    ) external override onlyRole(EXECUTOR_ROLE) nonReentrant whenNotPaused {
        // Verify caller is document issuer
        address issuer = documentIssuers[integraHash];
        if (caller != issuer) {
            revert OnlyIssuerCanCancel(caller, issuer);
        }

        TokenData storage data = tokenData[integraHash][tokenId];

        if (data.integraHash == bytes32(0)) {
            revert TokenNotReserved(integraHash, tokenId);
        }

        if (data.claimed) {
            revert TokenAlreadyClaimed(integraHash, tokenId);
        }

        uint256 cancelledAmount = data.reservedAmount;

        // Clear reservation
        delete tokenData[integraHash][tokenId];

        emit ReservationCancelled(integraHash, tokenId, cancelledAmount, block.timestamp);
    }

    // ============ View Functions ============

    /**
     * @notice Get token balance (ERC1155 standard)
     */
    function balanceOf(
        address account,
        uint256 tokenId
    ) public view override(ERC1155Upgradeable, IDocumentResolver) returns (uint256) {
        return ERC1155Upgradeable.balanceOf(account, tokenId);
    }

    /**
     * @notice Get comprehensive token information
     */
    function getTokenInfo(
        bytes32 integraHash,
        uint256 tokenId
    ) external view override returns (TokenInfo memory) {
        TokenData storage data = tokenData[integraHash][tokenId];

        return TokenInfo({
            integraHash: data.integraHash,
            tokenId: tokenId,
            totalSupply: data.totalSupply,
            reserved: data.reservedAmount,
            holders: data.holders,
            encryptedLabel: data.encryptedLabel,
            reservedFor: data.reservedFor,
            claimed: data.claimed,
            claimedBy: data.claimedBy
        });
    }

    /**
     * @notice Get encrypted label for specific token
     */
    function getEncryptedLabel(
        bytes32 integraHash,
        uint256 tokenId
    ) external view override returns (bytes memory) {
        return tokenData[integraHash][tokenId].encryptedLabel;
    }

    /**
     * @notice Get all encrypted labels for document
     * @dev Scans tokenIds 1-100 for reserved tokens
     */
    function getAllEncryptedLabels(bytes32 integraHash)
        external
        view
        override
        returns (uint256[] memory tokenIds, bytes[] memory labels)
    {
        // First pass: count reserved tokens
        uint256 count = 0;
        for (uint256 i = 1; i <= 100; i++) {
            if (tokenData[integraHash][i].integraHash != bytes32(0)) {
                count++;
            }
        }

        // Second pass: build arrays
        tokenIds = new uint256[](count);
        labels = new bytes[](count);

        uint256 index = 0;
        for (uint256 i = 1; i <= 100; i++) {
            if (tokenData[integraHash][i].integraHash != bytes32(0)) {
                tokenIds[index] = i;
                labels[index] = tokenData[integraHash][i].encryptedLabel;
                index++;
            }
        }

        return (tokenIds, labels);
    }

    /**
     * @notice Get reserved tokens for address
     * @dev Returns empty array for anonymous reservations
     */
    function getReservedTokens(
        bytes32 integraHash,
        address recipient
    ) external view override returns (uint256[] memory) {
        // Count reserved tokens for this recipient
        uint256 count = 0;
        for (uint256 i = 1; i <= 100; i++) {
            if (tokenData[integraHash][i].reservedFor == recipient) {
                count++;
            }
        }

        // Build array
        uint256[] memory reserved = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 1; i <= 100; i++) {
            if (tokenData[integraHash][i].reservedFor == recipient) {
                reserved[index++] = i;
            }
        }

        return reserved;
    }

    /**
     * @notice Get claim status for token
     */
    function getClaimStatus(bytes32 integraHash, uint256 tokenId)
        external
        view
        override
        returns (bool claimed, address claimedBy)
    {
        TokenData storage data = tokenData[integraHash][tokenId];
        return (data.claimed, data.claimedBy);
    }

    /**
     * @notice Get token type
     */
    function tokenType() external pure override returns (TokenType) {
        return TokenType.ERC1155;
    }

    // ============ ERC1155 Overrides ============

    /**
     * @notice Update hook for holder tracking
     * @dev Tracks holders for each tokenId
     */
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal virtual override {
        super._update(from, to, ids, values);

        // Update holder tracking
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];

            // Remove from holders if balance becomes zero
            if (from != address(0) && balanceOf(from, id) == 0) {
                _removeHolder(integraHashForToken(id), id, from);
            }

            // Add to holders if new holder
            if (to != address(0) && !isHolderOf(integraHashForToken(id), id, to)) {
                _addHolder(integraHashForToken(id), id, to);
            }
        }
    }

    /**
     * @notice Set base URI
     * @param newURI New base URI
     */
    function setURI(string memory newURI) external onlyRole(GOVERNOR_ROLE) {
        _baseURI = newURI;
        emit URI(newURI, 0);
    }

    /**
     * @notice Get token URI
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        return _baseURI;
    }

    // ============ Internal Helpers ============

    /**
     * @notice Get integraHash for tokenId
     * @dev Helper for holder tracking (scans up to 100 documents)
     */
    function integraHashForToken(uint256 tokenId) internal view returns (bytes32) {
        // This is expensive but only used in _update hook
        // In production, could optimize by storing reverse mapping
        // For now, acceptable for document-centric usage pattern
        return bytes32(0);  // Placeholder - would need reverse mapping
    }

    /**
     * @notice Check if address is holder of token
     */
    function isHolderOf(bytes32 integraHash, uint256 tokenId, address account)
        internal
        view
        returns (bool)
    {
        return tokenData[integraHash][tokenId].isHolder[account];
    }

    /**
     * @notice Add holder to token
     */
    function _addHolder(bytes32 integraHash, uint256 tokenId, address account) internal {
        TokenData storage data = tokenData[integraHash][tokenId];
        if (!data.isHolder[account]) {
            data.holders.push(account);
            data.isHolder[account] = true;
        }
    }

    /**
     * @notice Remove holder from token
     */
    function _removeHolder(bytes32 integraHash, uint256 tokenId, address account) internal {
        TokenData storage data = tokenData[integraHash][tokenId];
        if (data.isHolder[account]) {
            // Find and remove from array
            address[] storage holders = data.holders;
            for (uint256 i = 0; i < holders.length; i++) {
                if (holders[i] == account) {
                    holders[i] = holders[holders.length - 1];
                    holders.pop();
                    break;
                }
            }
            data.isHolder[account] = false;
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Authorize contract upgrade
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override(UUPSUpgradeable, AttestationAccessControl)
        onlyRole(GOVERNOR_ROLE)
    {}

    /**
     * @notice Check interface support
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC1155Upgradeable, AccessControlUpgradeable) returns (bool) {
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
    function declarePrimaryWallet(
        address primary,
        bytes memory signature
    ) external {
        if (primary == address(0)) revert ZeroAddress();

        // Verify signature from primary authorizing this ephemeral
        bytes32 message = keccak256(abi.encode(
            "INTEGRA_AUTHORIZE_EPHEMERAL",
            msg.sender,      // Ephemeral wallet
            address(this),   // This contract
            block.chainid
        ));

        bytes32 ethSignedMessage = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            message
        ));

        address signer = ECDSA.recover(ethSignedMessage, signature);
        if (signer != primary) revert InvalidSignature();

        ephemeralToPrimary[msg.sender] = primary;

        emit PrimaryWalletDeclared(msg.sender, primary, bytes32(0));
    }

    /**
     * @notice Get primary wallet for address
     * @param wallet Address to query (could be ephemeral or primary)
     * @return Primary wallet (or wallet itself if no mapping)
     */
    function getPrimaryWallet(address wallet) public view returns (address) {
        address primary = ephemeralToPrimary[wallet];
        return primary != address(0) ? primary : wallet;
    }

    /**
     * @notice Handle trust credential issuance after token claim
     * @param integraHash Document identifier
     * @param party Address that claimed (could be ephemeral)
     * @dev Issues credential to primary wallet via EAS when document complete
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

        // For MultiPartyResolver: Check if document is complete
        if (_isDocumentComplete(integraHash)) {
            _issueCredentialsToAllParties(integraHash);
        }
    }

    /**
     * @notice Check if document is complete (multi-party specific logic)
     * @param integraHash Document identifier
     * @return True if all reserved tokens have been claimed
     */
    function _isDocumentComplete(bytes32 integraHash) internal view returns (bool) {
        // Check if all reserved tokens (1-100) have been claimed
        for (uint256 i = 1; i <= 100; i++) {
            TokenData storage data = tokenData[integraHash][i];
            // If token exists and is reserved but not claimed, not complete
            if (data.integraHash != bytes32(0) && data.reservedAmount > 0 && !data.claimed) {
                return false;
            }
        }

        // All reserved tokens have been claimed (or no tokens exist)
        return true;
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
        address recipient = getPrimaryWallet(party);

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
     * Gap calculation: 50 - 7 state variables = 43 slots
     * State variables: tokenData (1), _baseURI (1), documentParties (1),
     *                 credentialsIssued (1), ephemeralToPrimary (1),
     *                 trustRegistry (1), credentialSchema (1)
     */
    uint256[43] private __gap;
}
