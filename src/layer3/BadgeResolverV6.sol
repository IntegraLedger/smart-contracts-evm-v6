// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/IDocumentResolver.sol";
import "../layer0/AttestationAccessControlV6.sol";

/**
 * @title BadgeResolverV6
 * @notice ERC-4671 resolver for non-tradable badges with revocation
 *
 * V6 ARCHITECTURE:
 * - Anonymous reservations (address unknown at reservation time)
 * - Encrypted labels for badge metadata
 * - Attestation-based access control (no ZK proofs)
 * - Simplified two-step workflow (reserve → claim)
 * - Revocation mechanism (invalidate without deletion)
 *
 * USE CASES:
 * - Revocable licenses (driver's licenses, business permits)
 * - Time-limited certifications (safety training, food handler permits)
 * - Membership badges (DAO/club membership)
 * - Event attendance (conference badges, workshop certificates)
 * - Government documents (marriage certificates)
 * - Product warranties (revocable if voided)
 *
 * CHARACTERISTICS:
 * - Non-transferable (no transfer functions)
 * - Revocable (isValid flag)
 * - Historical preservation (revoked badges remain in wallet)
 * - Optional pull mechanism (move between own addresses)
 *
 * WORKFLOW:
 * 1. Issuer reserves badge with encrypted label (address unknown)
 * 2. Recipient verifies eligibility off-chain
 * 3. Issuer issues capability attestation via EAS
 * 4. Recipient claims badge (non-transferable)
 * 5. Issuer can revoke badge (marks invalid, preserves history)
 *
 * ERC-4671 COMPLIANCE:
 * - Implements isValid() for revocation checking
 * - No transfer/transferFrom functions (non-tradable)
 * - Optional pull mechanism for wallet migration
 * - Historical record preservation
 */
contract BadgeResolverV6 is
    AttestationAccessControlV6,
    IDocumentResolver
{
    // ============ Constants ============

    uint256 public constant MAX_ENCRYPTED_LABEL_LENGTH = 500;
    uint256 public constant MAX_TOKENS_PER_DOCUMENT = 100;

    // ============ State Variables ============

    struct BadgeData {
        bytes32 integraHash;        // Document identifier
        address owner;              // Badge holder
        bool minted;                // Prevents double minting
        bool valid;                 // Revocation status (true = valid)
        address reservedFor;        // Specific address (or address(0) for anonymous)
        bytes encryptedLabel;       // Badge details
        uint256 issuanceDate;       // When badge was claimed
        uint256 expirationDate;     // Optional expiration (0 = no expiry)
        uint256 revocationDate;     // When revoked (0 = not revoked)
    }

    /// @notice Badge data by tokenId
    mapping(uint256 => BadgeData) private badgeData;

    /// @notice Reverse mapping: integraHash → tokenId
    mapping(bytes32 => uint256) public integraHashToTokenId;

    /// @notice All badges per holder
    mapping(address => uint256[]) private holderBadges;

    /// @notice Valid badge count per holder
    mapping(address => uint256) private holderValidCount;

    /// @notice Monotonic counter for tokenId generation
    uint256 private _nextTokenId;

    /// @notice Total badges emitted
    uint256 private _totalEmitted;

    /// @notice Token name
    string private _name;

    /// @notice Token symbol
    string private _symbol;

    /// @notice Base URI for token metadata
    string private _baseTokenURI;

    // ============ Trust Graph Integration ============

    mapping(bytes32 => address[]) private documentParties;
    mapping(bytes32 => bool) private credentialsIssued;
    address public trustRegistry;
    bytes32 public credentialSchema;

    // ============ Events ============

    event BadgeMinted(
        bytes32 indexed integraHash,
        uint256 indexed tokenId,
        address indexed owner,
        uint256 timestamp
    );

    event BadgeRevoked(
        bytes32 indexed integraHash,
        uint256 indexed tokenId,
        uint256 timestamp
    );

    event BadgePulled(
        address indexed from,
        address indexed to,
        uint256 indexed tokenId,
        uint256 timestamp
    );

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
    error OnlyIssuerCanRevoke(address caller, address issuer);
    error NotReservedForYou(address caller, address reservedFor);
    error ZeroAddress();
    error BadgeAlreadyRevoked(uint256 tokenId);
    error NotBadgeOwner(address caller, address owner);
    error InvalidSignature();
    error EncryptedLabelTooLarge(uint256 length, uint256 maximum);
    error NonTransferable();

    // ============ Constructor & Initialization ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

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

        __ReentrancyGuard_init();
        __AttestationAccessControl_init(_eas, _accessCapabilitySchema);

        _name = name_;
        _symbol = symbol_;
        _baseTokenURI = baseURI_;
        _nextTokenId = 1;
        _totalEmitted = 0;

        credentialSchema = _credentialSchema;
        trustRegistry = _trustRegistry;

        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
        _grantRole(EXECUTOR_ROLE, governor);
        _grantRole(OPERATOR_ROLE, governor);
    }

    // ============ Emergency Controls ============

    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // ============ IDocumentResolver Implementation ============

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

        badgeData[newTokenId] = BadgeData({
            integraHash: integraHash,
            owner: address(0),
            minted: false,
            valid: true,
            reservedFor: recipient,
            encryptedLabel: "",
            issuanceDate: 0,
            expirationDate: 0,
            revocationDate: 0
        });

        integraHashToTokenId[integraHash] = newTokenId;

        emit IDocumentResolver.TokenReserved(integraHash, newTokenId, recipient, 1, block.timestamp);
    }

    function reserveTokenAnonymous(
        address caller,
        bytes32 integraHash,
        uint256 tokenId,
        uint256 amount,
        bytes calldata encryptedLabel
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant whenNotPaused {
        if (encryptedLabel.length > MAX_ENCRYPTED_LABEL_LENGTH) {
            revert EncryptedLabelTooLarge(encryptedLabel.length, MAX_ENCRYPTED_LABEL_LENGTH);
        }

        uint256 existingTokenId = integraHashToTokenId[integraHash];
        if (existingTokenId != 0) {
            revert AlreadyReserved(integraHash);
        }

        uint256 newTokenId = _nextTokenId++;

        badgeData[newTokenId] = BadgeData({
            integraHash: integraHash,
            owner: address(0),
            minted: false,
            valid: true,
            reservedFor: address(0),
            encryptedLabel: encryptedLabel,
            issuanceDate: 0,
            expirationDate: 0,
            revocationDate: 0
        });

        integraHashToTokenId[integraHash] = newTokenId;

        emit IDocumentResolver.TokenReservedAnonymous(integraHash, newTokenId, 1, encryptedLabel, block.timestamp);
    }

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
        uint256 actualTokenId = tokenId != 0 ? tokenId : integraHashToTokenId[integraHash];

        if (actualTokenId == 0) {
            revert TokenNotFound(integraHash, tokenId);
        }

        BadgeData storage data = badgeData[actualTokenId];

        if (data.minted) {
            revert AlreadyMinted(actualTokenId);
        }

        if (data.reservedFor != address(0) && data.reservedFor != msg.sender) {
            revert NotReservedForYou(msg.sender, data.reservedFor);
        }

        // Mint badge to claimer
        data.owner = msg.sender;
        data.minted = true;
        data.valid = true;
        data.reservedFor = address(0);
        data.issuanceDate = block.timestamp;

        // Track badge for holder
        holderBadges[msg.sender].push(actualTokenId);
        holderValidCount[msg.sender]++;
        _totalEmitted++;

        emit IDocumentResolver.TokenClaimed(integraHash, actualTokenId, msg.sender, capabilityAttestationUID, block.timestamp);
        emit BadgeMinted(integraHash, actualTokenId, msg.sender, block.timestamp);

        _handleTrustCredential(integraHash, msg.sender);
    }

    function cancelReservation(
        address caller,
        bytes32 integraHash,
        uint256 tokenId
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant whenNotPaused {
        address issuer = documentIssuers[integraHash];
        if (caller != issuer) {
            revert OnlyIssuerCanCancel(caller, issuer);
        }

        uint256 actualTokenId = tokenId != 0 ? tokenId : integraHashToTokenId[integraHash];

        if (actualTokenId == 0) {
            revert TokenNotFound(integraHash, tokenId);
        }

        BadgeData storage data = badgeData[actualTokenId];

        if (data.minted) {
            revert AlreadyMinted(actualTokenId);
        }

        delete badgeData[actualTokenId];
        delete integraHashToTokenId[integraHash];

        emit IDocumentResolver.ReservationCancelled(integraHash, actualTokenId, 1, block.timestamp);
    }

    // ============ ERC-4671 Interface ============

    /**
     * @notice Get badge balance for address
     * @param owner Address to query
     * @return Total badge count (valid + invalid)
     */
    function balanceOf(address owner) public view returns (uint256) {
        return holderBadges[owner].length;
    }

    /**
     * @notice IDocumentResolver balanceOf override
     */
    function balanceOf(address account, uint256 tokenId) public view returns (uint256) {
        if (tokenId == 0) {
            return balanceOf(account);
        } else {
            if (badgeData[tokenId].owner == account && badgeData[tokenId].minted) {
                return 1;
            }
            return 0;
        }
    }

    /**
     * @notice Get badge owner
     * @param tokenId Badge ID
     * @return Owner address
     */
    function ownerOf(uint256 tokenId) public view returns (address) {
        return badgeData[tokenId].owner;
    }

    /**
     * @notice Check if badge is valid (not revoked, not expired)
     * @param tokenId Badge ID
     * @return True if valid
     */
    function isValid(uint256 tokenId) public view returns (bool) {
        BadgeData storage data = badgeData[tokenId];

        // Not minted = invalid
        if (!data.minted) return false;

        // Revoked = invalid
        if (!data.valid) return false;

        // Expired = invalid
        if (data.expirationDate > 0 && block.timestamp > data.expirationDate) {
            return false;
        }

        return true;
    }

    /**
     * @notice Check if address has at least one valid badge
     * @param owner Address to check
     * @return True if has valid badge
     */
    function hasValid(address owner) external view returns (bool) {
        return holderValidCount[owner] > 0;
    }

    /**
     * @notice Get total badges emitted
     * @return Total count
     */
    function emittedCount() external view returns (uint256) {
        return _totalEmitted;
    }

    /**
     * @notice Get count of unique badge holders
     * @return Holder count
     */
    function holdersCount() external view returns (uint256) {
        // Note: Simplified - doesn't track unique holders precisely
        // Full implementation would need separate counter
        return _totalEmitted;
    }

    /**
     * @notice Revoke badge (issuer only)
     * @param integraHash Document identifier
     * @param tokenId Token ID to revoke
     */
    function revoke(bytes32 integraHash, uint256 tokenId) external onlyRole(OPERATOR_ROLE) {
        address issuer = documentIssuers[integraHash];
        if (msg.sender != issuer && !hasRole(GOVERNOR_ROLE, msg.sender)) {
            revert OnlyIssuerCanRevoke(msg.sender, issuer);
        }

        uint256 actualTokenId = tokenId != 0 ? tokenId : integraHashToTokenId[integraHash];
        if (actualTokenId == 0) {
            revert TokenNotFound(integraHash, tokenId);
        }

        BadgeData storage data = badgeData[actualTokenId];

        if (!data.minted) {
            revert TokenNotFound(integraHash, tokenId);
        }

        if (!data.valid) {
            revert BadgeAlreadyRevoked(actualTokenId);
        }

        // Revoke badge (preserves historical record)
        data.valid = false;
        data.revocationDate = block.timestamp;

        // Update holder valid count
        if (holderValidCount[data.owner] > 0) {
            holderValidCount[data.owner]--;
        }

        emit BadgeRevoked(integraHash, actualTokenId, block.timestamp);
    }

    /**
     * @notice Pull badge to another address (wallet migration)
     * @param from Source address
     * @param to Destination address
     * @param tokenId Badge ID
     * @param signature Signature from 'to' address authorizing pull
     *
     * @dev Allows badge holder to move badge between their own addresses
     *      Requires signature from destination address as proof of ownership
     */
    function pull(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata signature
    ) external {
        if (msg.sender != from && msg.sender != to) revert NotBadgeOwner(msg.sender, from);
        if (to == address(0)) revert ZeroAddress();

        BadgeData storage data = badgeData[tokenId];

        if (data.owner != from) {
            revert NotBadgeOwner(from, data.owner);
        }

        // Verify signature from destination address
        bytes32 messageHash = keccak256(abi.encodePacked(from, to, tokenId));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        address signer = ECDSA.recover(ethSignedHash, signature);

        if (signer != to) {
            revert InvalidSignature();
        }

        // Move badge
        data.owner = to;

        // Update holder tracking
        _removeFromHolderBadges(from, tokenId);
        holderBadges[to].push(tokenId);

        // Update valid counts
        if (data.valid) {
            if (holderValidCount[from] > 0) {
                holderValidCount[from]--;
            }
            holderValidCount[to]++;
        }

        emit BadgePulled(from, to, tokenId, block.timestamp);
    }

    // ============ View Functions ============

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

        BadgeData storage data = badgeData[actualTokenId];

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

    function getEncryptedLabel(
        bytes32 integraHash,
        uint256 tokenId
    ) external view returns (bytes memory) {
        uint256 actualTokenId = tokenId != 0 ? tokenId : integraHashToTokenId[integraHash];
        return badgeData[actualTokenId].encryptedLabel;
    }

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
        labels[0] = badgeData[tokenId].encryptedLabel;

        return (tokenIds, labels);
    }

    function getReservedTokens(
        bytes32 integraHash,
        address recipient
    ) external view returns (uint256[] memory) {
        uint256 tokenId = integraHashToTokenId[integraHash];

        if (tokenId == 0) {
            return new uint256[](0);
        }

        BadgeData storage data = badgeData[tokenId];

        if (data.reservedFor == recipient && !data.minted) {
            uint256[] memory result = new uint256[](1);
            result[0] = tokenId;
            return result;
        }

        return new uint256[](0);
    }

    function getClaimStatus(bytes32 integraHash, uint256 tokenId)
        external
        view
        returns (bool claimed, address claimedBy)
    {
        uint256 actualTokenId = tokenId != 0 ? tokenId : integraHashToTokenId[integraHash];

        if (actualTokenId == 0) {
            return (false, address(0));
        }

        BadgeData storage data = badgeData[actualTokenId];
        return (data.minted, data.owner);
    }

    function tokenType() external pure returns (IDocumentResolver.TokenType) {
        return IDocumentResolver.TokenType.CUSTOM;
    }

    /**
     * @notice Get token name
     */
    function name() public view returns (string memory) {
        return _name;
    }

    /**
     * @notice Get token symbol
     */
    function symbol() public view returns (string memory) {
        return _symbol;
    }

    /**
     * @notice Get token URI
     */
    function tokenURI(uint256 tokenId) public view returns (string memory) {
        if (!badgeData[tokenId].minted) revert TokenNotFound(bytes32(0), tokenId);
        return string(abi.encodePacked(_baseTokenURI, _toString(tokenId)));
    }

    /**
     * @notice Set base URI
     */
    function setBaseURI(string memory baseURI_) external onlyRole(GOVERNOR_ROLE) {
        _baseTokenURI = baseURI_;
    }

    // ============ Internal Helpers ============

    function _removeFromHolderBadges(address holder, uint256 tokenId) internal {
        uint256[] storage badges = holderBadges[holder];
        for (uint256 i = 0; i < badges.length; i++) {
            if (badges[i] == tokenId) {
                badges[i] = badges[badges.length - 1];
                badges.pop();
                break;
            }
        }
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // ============ Admin Functions ============

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(GOVERNOR_ROLE)
    {}

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControlUpgradeable) returns (bool) {
        return
            interfaceId == type(IDocumentResolver).interfaceId ||
            interfaceId == 0x0d4a9f6b ||  // ERC-4671
            super.supportsInterface(interfaceId);
    }

    // ============ Trust Graph Integration ============

    function _handleTrustCredential(bytes32 integraHash, address party) internal {
        if (trustRegistry == address(0)) return;
        if (credentialsIssued[integraHash]) return;

        if (!_isPartyTracked(integraHash, party)) {
            documentParties[integraHash].push(party);
        }

        _issueCredentialsToAllParties(integraHash);
    }

    function _issueCredentialsToAllParties(bytes32 integraHash) internal {
        address[] memory parties = documentParties[integraHash];

        for (uint i = 0; i < parties.length; i++) {
            _issueCredentialToParty(parties[i], integraHash);
        }

        credentialsIssued[integraHash] = true;

        emit TrustCredentialsIssued(integraHash, parties.length, block.timestamp);
    }

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
                // Don't block claiming if credential fails
            }
        }
    }

    function _isPartyTracked(bytes32 integraHash, address party) internal view returns (bool) {
        address[] memory parties = documentParties[integraHash];
        for (uint i = 0; i < parties.length; i++) {
            if (parties[i] == party) return true;
        }
        return false;
    }

    // ============ Storage Gap ============

    uint256[50] private __gap;
}
