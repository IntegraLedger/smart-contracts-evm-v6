// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDocumentResolver
 * @notice Standard interface for document tokenization strategies
 *
 * V6 ARCHITECTURE:
 * - Supports anonymous reservations (address unknown at reservation time)
 * - Encrypted labels for privacy-preserving role identification
 * - Attestation-based access control (no ZK proofs needed)
 * - Simplified two-step workflow (reserve → claim)
 *
 * DESIGN PRINCIPLES:
 * - Document-as-credential (possession proves relationship)
 * - Real identity disclosure between parties (not privacy-preserving)
 * - Capability attestations replace complex proof systems
 * - Labels encrypted with integraID (discoverable but private)
 */
interface IDocumentResolver {
    // ============ Types ============

    /**
     * @notice Token standard type
     */
    enum TokenType {
        ERC20,      // Fungible shares (SharesResolver)
        ERC721,     // Unique NFT (OwnershipResolver)
        ERC1155,    // Multi-token (MultiPartyResolver)
        CUSTOM      // Custom implementation
    }

    /**
     * @notice Token information
     */
    struct TokenInfo {
        bytes32 integraHash;        // Document identifier
        uint256 tokenId;            // Token ID (0 for ERC20)
        uint256 totalSupply;        // Total minted tokens
        uint256 reserved;           // Reserved but not yet minted
        address[] holders;          // Current token holders
        bytes encryptedLabel;       // Encrypted label (decrypt with integraID)
        address reservedFor;        // Specific address (or address(0) for anonymous)
        bool claimed;               // Whether token has been claimed
        address claimedBy;          // Who claimed the token
    }

    // ============ Events ============

    /**
     * @notice Emitted when token is reserved for specific address
     */
    event TokenReserved(
        bytes32 indexed integraHash,
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );

    /**
     * @notice Emitted when token is reserved anonymously (address unknown)
     */
    event TokenReservedAnonymous(
        bytes32 indexed integraHash,
        uint256 indexed tokenId,
        uint256 amount,
        bytes encryptedLabel,
        uint256 timestamp
    );

    /**
     * @notice Emitted when token is claimed
     */
    event TokenClaimed(
        bytes32 indexed integraHash,
        uint256 indexed tokenId,
        address indexed claimant,
        bytes32 capabilityAttestation,
        uint256 timestamp
    );

    /**
     * @notice Emitted when reservation is cancelled
     */
    event ReservationCancelled(
        bytes32 indexed integraHash,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 timestamp
    );

    // ============ Core Functions ============

    /**
     * @notice Reserve token for specific address (address-based reservation)
     * @param caller Caller address (for access control)
     * @param integraHash Document identifier
     * @param tokenId Token ID to reserve
     * @param recipient Address to reserve for
     * @param amount Amount to reserve
     *
     * @dev Use when recipient address is known upfront
     */
    function reserveToken(
        address caller,
        bytes32 integraHash,
        uint256 tokenId,
        address recipient,
        uint256 amount
    ) external;

    /**
     * @notice Reserve token anonymously (address unknown at reservation time)
     * @param caller Caller address (for access control)
     * @param integraHash Document identifier
     * @param tokenId Token ID to reserve
     * @param amount Amount to reserve
     * @param encryptedLabel Role/party label encrypted with integraID
     *
     * @dev Use when recipient address is unknown (will be determined at claim time)
     *      Label should be encrypted with: keccak256(integraID)
     */
    function reserveTokenAnonymous(
        address caller,
        bytes32 integraHash,
        uint256 tokenId,
        uint256 amount,
        bytes calldata encryptedLabel
    ) external;

    /**
     * @notice Claim reserved token with attestation-based access control
     * @param integraHash Document identifier
     * @param tokenId Token ID to claim
     * @param capabilityAttestationUID EAS attestation proving claim capability
     *
     * @dev Simplified two-step workflow (reserve → claim)
     *      Attestation replaces request+approve steps from V5
     *      No ZK proof needed - attestation provides access control
     */
    function claimToken(
        bytes32 integraHash,
        uint256 tokenId,
        bytes32 capabilityAttestationUID
    ) external;

    /**
     * @notice Cancel reservation (issuer only)
     * @param caller Caller address (must be issuer)
     * @param integraHash Document identifier
     * @param tokenId Token ID to cancel
     */
    function cancelReservation(
        address caller,
        bytes32 integraHash,
        uint256 tokenId
    ) external;

    // ============ View Functions ============

    /**
     * @notice Get token balance for address
     * @param account Address to query
     * @param tokenId Token ID (ignored for ERC20, used for ERC721/ERC1155)
     * @return Token balance
     */
    function balanceOf(address account, uint256 tokenId) external view returns (uint256);

    /**
     * @notice Get comprehensive token information
     * @param integraHash Document identifier
     * @param tokenId Token ID
     * @return Token information struct
     */
    function getTokenInfo(bytes32 integraHash, uint256 tokenId) external view returns (TokenInfo memory);

    /**
     * @notice Get encrypted label for token
     * @param integraHash Document identifier
     * @param tokenId Token ID
     * @return Encrypted label bytes (decrypt with integraID)
     *
     * @dev Label encrypted with: keccak256(integraID)
     *      Anyone can query but only those with integraID can decrypt
     */
    function getEncryptedLabel(bytes32 integraHash, uint256 tokenId) external view returns (bytes memory);

    /**
     * @notice Get all encrypted labels for document
     * @param integraHash Document identifier
     * @return tokenIds Array of token IDs
     * @return labels Array of encrypted labels (parallel to tokenIds)
     *
     * @dev Useful for discovering all available tokens in a document
     */
    function getAllEncryptedLabels(bytes32 integraHash)
        external
        view
        returns (uint256[] memory tokenIds, bytes[] memory labels);

    /**
     * @notice Get reserved tokens for address
     * @param integraHash Document identifier
     * @param recipient Address to check
     * @return Array of token IDs reserved for recipient
     *
     * @dev Returns empty array for anonymous reservations
     */
    function getReservedTokens(bytes32 integraHash, address recipient) external view returns (uint256[] memory);

    /**
     * @notice Get token type
     * @return Token standard (ERC20, ERC721, ERC1155, CUSTOM)
     */
    function tokenType() external view returns (TokenType);

    /**
     * @notice Check if token has been claimed
     * @param integraHash Document identifier
     * @param tokenId Token ID
     * @return claimed Whether token is claimed
     * @return claimedBy Address that claimed (address(0) if not claimed)
     */
    function getClaimStatus(bytes32 integraHash, uint256 tokenId)
        external
        view
        returns (bool claimed, address claimedBy);
}
