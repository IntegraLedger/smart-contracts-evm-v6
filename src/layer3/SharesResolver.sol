// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/IDocumentResolver.sol";
import "../layer0/AttestationAccessControl.sol";

/**
 * @title SharesResolver
 * @notice ERC-20 Votes resolver for fractional ownership with checkpoint-based pro-rata distribution
 *
 * V6 ARCHITECTURE:
 * - Anonymous reservations (address unknown at reservation time)
 * - Encrypted labels for share description
 * - Attestation-based access control (no ZK proofs)
 * - Simplified two-step workflow (reserve → claim)
 * - Checkpoint mechanism for pro-rata payment distribution (ERC20Votes)
 *
 * USE CASES:
 * - Investment shares (multiple investors, fractional ownership)
 * - Revenue rights (pro-rata distribution to shareholders)
 * - Collective ownership (community-owned assets)
 * - Fractional real estate (multiple owners per property)
 *
 * CHARACTERISTICS:
 * - Fungible shares (divisible, transferable)
 * - Checkpoint mechanism (block-based historical balances for payments)
 * - Multiple holders per document
 * - Pro-rata distribution support via ERC20Votes
 *
 * WORKFLOW:
 * 1. Issuer reserves shares with encrypted label (addresses unknown)
 * 2. Investors verify identity off-chain (email, DocuSign, etc.)
 * 3. Issuer issues capability attestations via EAS
 * 4. Investors claim shares using attestations (no ZK proof needed)
 * 5. Payment distribution uses checkpoints (fair pro-rata allocation based on past votes)
 */
contract SharesResolver is
    ERC20VotesUpgradeable,
    AttestationAccessControl,
    IDocumentResolver
{
    // ============ Constants ============

    uint256 public constant MAX_ENCRYPTED_LABEL_LENGTH = 10000;
    uint256 public constant MAX_TOKENS_PER_DOCUMENT = 100;

    // ============ State Variables ============

    struct ShareTokenData {
        bytes32 integraHash;                          // Document identifier
        uint256 totalShares;                          // Total minted shares
        uint256 reservedShares;                       // Total reserved (not yet minted)
        bytes encryptedLabel;                         // Share description encrypted with integraID
        mapping(address => uint256) reservations;     // Per-address reservations
        mapping(address => bool) claimed;             // Track who has claimed
        address[] holders;                            // Current shareholders
        uint256 firstClaimTime;                       // Timestamp of first claim (for timeout logic)
    }

    /// @notice Share data by integraHash (one share pool per document)
    mapping(bytes32 => ShareTokenData) private tokenData;

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
    event CheckpointCreated(
        uint256 indexed blockNumber,
        uint256 timestamp
    );

    event SharesMinted(
        bytes32 indexed integraHash,
        address indexed recipient,
        uint256 amount,
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
    error AlreadyReserved(bytes32 integraHash, address recipient);
    error NoReservation(bytes32 integraHash, address recipient);
    error AlreadyClaimed(address claimer);
    error OnlyIssuerCanCancel(address caller, address issuer);
    error InsufficientReservedShares(uint256 requested, uint256 available);
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
     * @param name_ ERC-20 token name
     * @param symbol_ ERC-20 token symbol
     * @param governor Governor address (admin role)
     * @param _eas EAS contract address
     * @param _accessCapabilitySchema Capability attestation schema UID
     * @param _credentialSchema Credential hash schema UID (for trust graph)
     * @param _trustRegistry Trust registry address (address(0) to disable trust graph)
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        address governor,
        address _eas,
        bytes32 _accessCapabilitySchema,
        bytes32 _credentialSchema,
        address _trustRegistry
    ) external initializer {
        if (governor == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __ERC20Votes_init();
        __ReentrancyGuard_init();
        __AttestationAccessControl_init(_eas, _accessCapabilitySchema);  // Calls __UUPSUpgradeable_init and __AccessControl_init internally

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
     * @notice Pause all share operations (emergency use only)
     * @dev Pauses claimToken, reserveToken, reserveTokenAnonymous, cancelReservation
     *      Admin functions remain active for emergency response
     */
    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause share operations
     */
    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // ============ IDocumentResolver Implementation ============

    /**
     * @notice Reserve shares for specific address
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

        ShareTokenData storage data = tokenData[integraHash];

        if (data.reservations[recipient] > 0) {
            revert AlreadyReserved(integraHash, recipient);
        }

        if (data.integraHash == bytes32(0)) {
            data.integraHash = integraHash;
        }

        data.reservations[recipient] = amount;
        data.reservedShares += amount;

        emit TokenReserved(integraHash, 0, recipient, amount, block.timestamp);
    }

    /**
     * @notice Reserve shares anonymously (addresses unknown)
     * @dev Use when recipient addresses are unknown at reservation time
     *      Multiple investors can claim from same share pool
     *      This is the PRIMARY function for Integra's fractional ownership use case
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

        ShareTokenData storage data = tokenData[integraHash];

        if (data.integraHash == bytes32(0)) {
            data.integraHash = integraHash;
            data.encryptedLabel = encryptedLabel;
        }

        data.reservedShares += amount;

        emit TokenReservedAnonymous(integraHash, 0, amount, encryptedLabel, block.timestamp);
    }

    /**
     * @notice Claim reserved shares with attestation
     * @param integraHash Document identifier
     * @param tokenId Token ID (ignored for ERC20 - included for interface compatibility)
     * @param capabilityAttestationUID EAS attestation proving claim capability
     *
     * @dev Simplified workflow - attestation IS the approval
     *      For SharesResolver, claims are fulfilled from anonymous share pool
     *      Attestation specifies how many shares this party can claim
     *
     * ACCESS CONTROL:
     * - Requires valid capability attestation from document issuer
     * - Attestation must grant CAPABILITY_CLAIM_TOKEN
     * - Attestation data should include share amount in tokenId field
     * - Attestation must not be revoked or expired
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
        ShareTokenData storage data = tokenData[integraHash];

        require(data.integraHash != bytes32(0), "Shares not reserved");
        require(!data.claimed[msg.sender], "Already claimed");

        // Get claim amount from attestation
        // For SharesResolver, amount is encoded in attestation's tokenId field
        uint256 claimAmount = tokenId;
        if (claimAmount == 0) {
            // If not specified, check if there's an address-specific reservation
            claimAmount = data.reservations[msg.sender];
            require(claimAmount > 0, "No reservation and no amount specified");
        }

        if (claimAmount > data.reservedShares) {
            revert InsufficientReservedShares(claimAmount, data.reservedShares);
        }

        // Mint shares to claimer
        _mint(msg.sender, claimAmount);

        // Update state
        data.totalShares += claimAmount;
        data.reservedShares -= claimAmount;
        data.claimed[msg.sender] = true;

        // Track first claim time (for timeout logic)
        if (data.firstClaimTime == 0) {
            data.firstClaimTime = block.timestamp;
        }

        // Track holder
        if (claimAmount == balanceOf(msg.sender)) {
            data.holders.push(msg.sender);
        }

        // Remove address-specific reservation if exists
        if (data.reservations[msg.sender] > 0) {
            delete data.reservations[msg.sender];
        }

        emit TokenClaimed(integraHash, 0, msg.sender, capabilityAttestationUID, block.timestamp);
        emit SharesMinted(integraHash, msg.sender, claimAmount, block.timestamp);

        // TRUST GRAPH: Track party and issue credential if document complete
        _handleTrustCredential(integraHash, msg.sender);
    }

    /**
     * @notice Cancel reservation (issuer only)
     * @param caller Caller address
     * @param integraHash Document identifier
     * @param tokenId Amount to cancel (for SharesResolver, this is the amount not tokenId)
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

        ShareTokenData storage data = tokenData[integraHash];

        require(data.integraHash != bytes32(0), "No reservation");

        uint256 cancelAmount = tokenId != 0 ? tokenId : data.reservedShares;

        require(cancelAmount <= data.reservedShares, "Amount exceeds reserved");

        data.reservedShares -= cancelAmount;

        emit ReservationCancelled(integraHash, 0, cancelAmount, block.timestamp);
    }

    // ============ Checkpoint Functions (ERC20Votes) ============

    /**
     * @notice Get current block number for checkpoint reference
     * @return Current block number
     *
     * @dev Used for pro-rata payment distribution
     *      Call before distributing payments to record the block number
     *      ERC20Votes automatically creates checkpoints on every transfer
     *
     * NOTE: Checkpoints are created automatically - no manual snapshot needed
     */
    function getCurrentCheckpoint() external view returns (uint256) {
        uint256 blockNumber = clock();
        return blockNumber;
    }

    /**
     * @notice Get voting power (shares) at specific block
     * @param account Address to query
     * @param blockNumber Block number for historical lookup
     * @return Balance at that block (must be in the past)
     *
     * @dev Critical for pro-rata payment calculations
     *      NOTE: blockNumber must be < current block
     *      Shareholders must delegate to themselves for tracking (auto-delegated on mint)
     */
    function balanceOfAt(
        address account,
        uint256 blockNumber
    ) public view returns (uint256) {
        return getPastVotes(account, blockNumber);
    }

    /**
     * @notice Get total supply at specific block
     * @param blockNumber Block number for historical lookup
     * @return Total supply at that block (must be in the past)
     */
    function totalSupplyAt(uint256 blockNumber) public view returns (uint256) {
        return getPastTotalSupply(blockNumber);
    }

    // ============ View Functions ============

    /**
     * @notice Get token balance (ERC-20 standard)
     * @param account Address to query
     * @param tokenId Ignored (ERC20 has no token IDs)
     */
    function balanceOf(
        address account,
        uint256 tokenId
    ) public view override returns (uint256) {
        return super.balanceOf(account);
    }

    /**
     * @notice Get comprehensive token information
     */
    function getTokenInfo(
        bytes32 integraHash,
        uint256 tokenId
    ) external view override returns (TokenInfo memory) {
        ShareTokenData storage data = tokenData[integraHash];

        return TokenInfo({
            integraHash: data.integraHash,
            tokenId: 0,  // ERC20 has no token IDs
            totalSupply: data.totalShares,
            reserved: data.reservedShares,
            holders: data.holders,
            encryptedLabel: data.encryptedLabel,
            reservedFor: address(0),  // ERC20 doesn't have address-specific reservations
            claimed: false,  // Not applicable to fungible shares
            claimedBy: address(0)  // Not applicable
        });
    }

    /**
     * @notice Get encrypted label for shares
     */
    function getEncryptedLabel(
        bytes32 integraHash,
        uint256 tokenId
    ) external view override returns (bytes memory) {
        return tokenData[integraHash].encryptedLabel;
    }

    /**
     * @notice Get all encrypted labels for document
     * @dev SharesResolver only has one label per document (fungible shares)
     */
    function getAllEncryptedLabels(bytes32 integraHash)
        external
        view
        override
        returns (uint256[] memory tokenIds, bytes[] memory labels)
    {
        ShareTokenData storage data = tokenData[integraHash];

        if (data.integraHash == bytes32(0)) {
            return (new uint256[](0), new bytes[](0));
        }

        tokenIds = new uint256[](1);
        labels = new bytes[](1);

        tokenIds[0] = 0;  // ERC20 uses tokenId 0
        labels[0] = data.encryptedLabel;

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
        uint256 reserved = tokenData[integraHash].reservations[recipient];

        if (reserved == 0) {
            return new uint256[](0);
        }

        uint256[] memory result = new uint256[](1);
        result[0] = 0;  // ERC20 uses tokenId 0
        return result;
    }

    /**
     * @notice Get claim status
     * @dev For SharesResolver, tracks if address has claimed (not per-token)
     */
    function getClaimStatus(bytes32 integraHash, uint256 tokenId)
        external
        view
        override
        returns (bool claimed, address claimedBy)
    {
        // SharesResolver doesn't track individual claims (fungible shares)
        // Return total shares info instead
        ShareTokenData storage data = tokenData[integraHash];
        return (data.totalShares > 0, address(0));
    }

    /**
     * @notice Get token type
     */
    function tokenType() external pure override returns (TokenType) {
        return TokenType.ERC20;
    }

    // ============ Internal Overrides ============

    /**
     * @notice Update hook (required for ERC20Votes)
     * @dev Auto-delegates to self on first token receipt for checkpoint tracking
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        super._update(from, to, value);

        // Auto-delegate on first token receipt (minting or transfer)
        // This ensures voting power (shares) are tracked in checkpoints
        if (to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);  // Delegate to self for checkpoint tracking
        }

        // Note: Holder tracking could be added here if needed
        // For now, holders are tracked at claim time
    }

    // ============ ERC20Votes Overrides ============

    /**
     * @notice Clock mode for ERC20Votes (uses block number)
     * @dev Required by ERC6372
     */
    function clock() public view override returns (uint48) {
        return uint48(block.number);
    }

    /**
     * @notice Clock mode identifier
     * @dev Required by ERC6372 - returns "mode=blocknumber&from=default"
     */
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=blocknumber&from=default";
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
    ) public view override(AccessControlUpgradeable) returns (bool) {
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

        // For SharesResolver: Check if document is complete
        if (_isDocumentComplete(integraHash)) {
            _issueCredentialsToAllParties(integraHash);
        }
    }

    /**
     * @notice Check if document is complete (shares-specific logic)
     * @param integraHash Document identifier
     * @return True if all shares claimed OR timeout reached
     */
    function _isDocumentComplete(bytes32 integraHash) internal view returns (bool) {
        ShareTokenData storage data = tokenData[integraHash];

        // All shares claimed
        if (data.reservedShares == 0 && data.totalShares > 0) return true;

        // Timeout (30 days after first claim)
        if (data.firstClaimTime > 0 &&
            block.timestamp > data.firstClaimTime + 30 days) {
            return true;
        }

        return false;
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
     * Gap calculation: 50 - 6 state variables = 44 slots
     * State variables: tokenData (1), documentParties (1), credentialsIssued (1),
     *                 ephemeralToPrimary (1), trustRegistry (1), credentialSchema (1)
     */
    uint256[44] private __gap;
}
