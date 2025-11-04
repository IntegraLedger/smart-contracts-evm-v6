// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IDocumentResolver.sol";
import "../layer0/AttestationAccessControlV6.sol";

/**
 * @title RentalResolverV6
 * @notice ERC-4907 resolver for time-limited usage rights separate from ownership
 *
 * V6 ARCHITECTURE:
 * - Anonymous reservations (address unknown at reservation time)
 * - Encrypted labels for lease terms
 * - Attestation-based access control (no ZK proofs)
 * - Simplified two-step workflow (reserve → claim)
 * - Owner/user role separation
 *
 * USE CASES:
 * - Residential leases (landlord = owner, tenant = user)
 * - Commercial leases (property owner vs business tenant)
 * - Equipment rentals (construction, medical, vehicles)
 * - Software/IP licenses (time-limited usage rights)
 * - Timeshare properties (rotating usage schedules)
 * - Event access (conference, gym memberships)
 * - Subscription services (content access, SaaS platforms)
 * - Gaming assets (virtual land leasing, item rentals)
 * - Rent-to-own agreements
 *
 * CHARACTERISTICS:
 * - Owner retains NFT ownership
 * - User gets temporary access rights
 * - Automatic expiration (no manual revocation)
 * - Owner can transfer NFT (user role cleared)
 * - User cannot transfer
 *
 * WORKFLOW:
 * 1. Owner reserves rental NFT with encrypted label
 * 2. Prospective tenant applies off-chain (credit check, etc.)
 * 3. Owner issues capability attestation to approved tenant
 * 4. Tenant claims NFT (minted to owner, user set to tenant)
 * 5. Lease expiration: userOf() automatically returns address(0)
 * 6. Owner can setUser() to extend or change tenant
 *
 * ERC-4907 COMPLIANCE:
 * - Implements setUser(), userOf(), userExpires()
 * - Owner and user roles distinct
 * - Automatic expiration checking
 */
contract RentalResolverV6 is
    ERC721Upgradeable,
    AttestationAccessControlV6,
    IDocumentResolver
{
    // ============ Constants ============

    uint256 public constant MAX_ENCRYPTED_LABEL_LENGTH = 500;
    uint256 public constant MAX_TOKENS_PER_DOCUMENT = 100;

    // ============ ERC-4907 Interface ID ============

    bytes4 private constant _INTERFACE_ID_ERC4907 = 0xad092b5c;

    // ============ State Variables ============

    struct UserInfo {
        address user;               // Current tenant/user
        uint64 expires;             // Lease expiration timestamp
    }

    struct RentalTokenData {
        bytes32 integraHash;        // Document identifier
        address owner;              // Property owner (NFT holder)
        bool minted;                // Prevents double minting
        address reservedFor;        // Specific address (or address(0) for anonymous)
        bytes encryptedLabel;       // Lease terms
        uint256 monthlyPayment;     // Rent amount (optional, for tracking)
        uint256 securityDeposit;    // Escrowed deposit (optional)
        uint256 lastPaymentDate;    // Last rent payment timestamp
    }

    /// @notice Token data by tokenId
    mapping(uint256 => RentalTokenData) private tokenData;

    /// @notice User info by tokenId (ERC-4907)
    mapping(uint256 => UserInfo) private _users;

    /// @notice Reverse mapping: integraHash → tokenId
    mapping(bytes32 => uint256) public integraHashToTokenId;

    /// @notice Payment tracking for rent-to-own
    mapping(bytes32 => mapping(address => uint256)) public paymentsMade;

    /// @notice Required payments for ownership transfer (rent-to-own)
    mapping(bytes32 => uint256) public paymentsRequired;

    /// @notice Monotonic counter for tokenId generation
    uint256 private _nextTokenId;

    /// @notice Base URI for token metadata
    string private _baseTokenURI;

    // ============ Trust Graph Integration ============

    mapping(bytes32 => address[]) private documentParties;
    mapping(bytes32 => bool) private credentialsIssued;
    address public trustRegistry;
    bytes32 public credentialSchema;

    // ============ Events ============

    // ERC-4907 event
    event UpdateUser(uint256 indexed tokenId, address indexed user, uint64 expires);

    event TokenMinted(
        bytes32 indexed integraHash,
        uint256 indexed tokenId,
        address indexed owner,
        uint256 timestamp
    );

    event LeaseExtended(
        uint256 indexed tokenId,
        address indexed user,
        uint64 newExpiration,
        uint256 timestamp
    );

    event RentPaymentMade(
        bytes32 indexed integraHash,
        uint256 indexed tokenId,
        address indexed payer,
        uint256 amount,
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
    error NotReservedForYou(address caller, address reservedFor);
    error ZeroAddress();
    error OnlyOwnerCanSetUser(address caller, address owner);
    error EncryptedLabelTooLarge(uint256 length, uint256 maximum);

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

        __ERC721_init(name_, symbol_);
        __ReentrancyGuard_init();
        __AttestationAccessControl_init(_eas, _accessCapabilitySchema);

        _baseTokenURI = baseURI_;
        _nextTokenId = 1;

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

        tokenData[newTokenId] = RentalTokenData({
            integraHash: integraHash,
            owner: address(0),
            minted: false,
            reservedFor: recipient,
            encryptedLabel: "",
            monthlyPayment: 0,
            securityDeposit: 0,
            lastPaymentDate: 0
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

        tokenData[newTokenId] = RentalTokenData({
            integraHash: integraHash,
            owner: address(0),
            minted: false,
            reservedFor: address(0),
            encryptedLabel: encryptedLabel,
            monthlyPayment: 0,
            securityDeposit: 0,
            lastPaymentDate: 0
        });

        integraHashToTokenId[integraHash] = newTokenId;

        emit IDocumentResolver.TokenReservedAnonymous(integraHash, newTokenId, 1, encryptedLabel, block.timestamp);
    }

    /**
     * @notice Claim rental NFT
     * @dev For rental, the OWNER claims (not the user/tenant)
     *      User is set separately via setUser() after claiming
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
        uint256 actualTokenId = tokenId != 0 ? tokenId : integraHashToTokenId[integraHash];

        if (actualTokenId == 0) {
            revert TokenNotFound(integraHash, tokenId);
        }

        RentalTokenData storage data = tokenData[actualTokenId];

        if (data.minted) {
            revert AlreadyMinted(actualTokenId);
        }

        if (data.reservedFor != address(0) && data.reservedFor != msg.sender) {
            revert NotReservedForYou(msg.sender, data.reservedFor);
        }

        // Mint NFT to claimer (property owner)
        _safeMint(msg.sender, actualTokenId);

        // Update state
        data.owner = msg.sender;
        data.minted = true;
        data.reservedFor = address(0);

        emit IDocumentResolver.TokenClaimed(integraHash, actualTokenId, msg.sender, capabilityAttestationUID, block.timestamp);
        emit TokenMinted(integraHash, actualTokenId, msg.sender, block.timestamp);

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

        RentalTokenData storage data = tokenData[actualTokenId];

        if (data.minted) {
            revert AlreadyMinted(actualTokenId);
        }

        delete tokenData[actualTokenId];
        delete integraHashToTokenId[integraHash];

        emit IDocumentResolver.ReservationCancelled(integraHash, actualTokenId, 1, block.timestamp);
    }

    // ============ ERC-4907 Interface ============

    /**
     * @notice Set user and expiration for rental NFT
     * @param tokenId Token ID
     * @param user Tenant/user address
     * @param expires Lease expiration timestamp
     */
    function setUser(uint256 tokenId, address user, uint64 expires) external {
        address owner = _ownerOf(tokenId);

        // Only owner or authorized executor can set user
        if (msg.sender != owner && !hasRole(EXECUTOR_ROLE, msg.sender)) {
            revert OnlyOwnerCanSetUser(msg.sender, owner);
        }

        UserInfo storage info = _users[tokenId];
        info.user = user;
        info.expires = expires;

        // Track user as party for trust credentials
        if (user != address(0)) {
            _handleTrustCredential(tokenData[tokenId].integraHash, user);
        }

        emit UpdateUser(tokenId, user, expires);
    }

    /**
     * @notice Get current user (returns address(0) if expired)
     * @param tokenId Token ID
     * @return Current user address
     */
    function userOf(uint256 tokenId) external view returns (address) {
        UserInfo storage info = _users[tokenId];
        if (info.expires >= block.timestamp) {
            return info.user;
        }
        return address(0);
    }

    /**
     * @notice Get user expiration timestamp
     * @param tokenId Token ID
     * @return Expiration timestamp
     */
    function userExpires(uint256 tokenId) external view returns (uint256) {
        return _users[tokenId].expires;
    }

    // ============ Payment Tracking ============

    /**
     * @notice Record rent payment
     * @param integraHash Document identifier
     * @param amount Payment amount
     */
    function recordPayment(
        bytes32 integraHash,
        uint256 amount
    ) external payable {
        uint256 tokenId = integraHashToTokenId[integraHash];
        if (tokenId == 0) revert TokenNotFound(integraHash, 0);

        RentalTokenData storage data = tokenData[tokenId];
        data.lastPaymentDate = block.timestamp;

        // Track for rent-to-own
        paymentsMade[integraHash][msg.sender] += amount;

        emit RentPaymentMade(integraHash, tokenId, msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Set rent-to-own requirements
     * @param integraHash Document identifier
     * @param requiredPayments Total payments needed for ownership transfer
     */
    function setRentToOwnRequirements(
        bytes32 integraHash,
        uint256 requiredPayments
    ) external onlyRole(OPERATOR_ROLE) {
        paymentsRequired[integraHash] = requiredPayments;
    }

    /**
     * @notice Check if user eligible for rent-to-own conversion
     * @param integraHash Document identifier
     * @param user User address
     * @return True if eligible
     */
    function isEligibleForOwnership(
        bytes32 integraHash,
        address user
    ) external view returns (bool) {
        uint256 required = paymentsRequired[integraHash];
        if (required == 0) return false;
        return paymentsMade[integraHash][user] >= required;
    }

    // ============ Transfer Override (Clear User on Transfer) ============

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);

        // Clear user role when ownership transfers
        if (from != address(0) && to != address(0)) {
            delete _users[tokenId];
            emit UpdateUser(tokenId, address(0), 0);
        }

        // Update owner tracking
        if (to != address(0)) {
            tokenData[tokenId].owner = to;
        }

        return super._update(to, tokenId, auth);
    }

    // ============ View Functions ============

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

        RentalTokenData storage data = tokenData[actualTokenId];

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
        return tokenData[actualTokenId].encryptedLabel;
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
        labels[0] = tokenData[tokenId].encryptedLabel;

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

        RentalTokenData storage data = tokenData[tokenId];

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

        RentalTokenData storage data = tokenData[actualTokenId];
        return (data.minted, data.owner);
    }

    function tokenType() external pure returns (IDocumentResolver.TokenType) {
        return IDocumentResolver.TokenType.ERC721;
    }

    // ============ ERC-721 Overrides ============

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function setBaseURI(string memory baseURI_) external onlyRole(GOVERNOR_ROLE) {
        _baseTokenURI = baseURI_;
    }

    // ============ Admin Functions ============

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(GOVERNOR_ROLE)
    {}

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721Upgradeable, AccessControlUpgradeable) returns (bool) {
        return
            interfaceId == type(IDocumentResolver).interfaceId ||
            interfaceId == _INTERFACE_ID_ERC4907 ||
            super.supportsInterface(interfaceId);
    }

    // ============ Trust Graph Integration ============

    function _handleTrustCredential(bytes32 integraHash, address party) internal {
        if (trustRegistry == address(0)) return;
        if (credentialsIssued[integraHash]) return;

        if (!_isPartyTracked(integraHash, party)) {
            documentParties[integraHash].push(party);
        }

        // For RentalResolver: Issue credentials when lease completes successfully
        // (This is simplified - full implementation would check lease completion)
        if (_isLeaseComplete(integraHash)) {
            _issueCredentialsToAllParties(integraHash);
        }
    }

    function _isLeaseComplete(bytes32 integraHash) internal view returns (bool) {
        uint256 tokenId = integraHashToTokenId[integraHash];
        if (tokenId == 0) return false;

        UserInfo storage info = _users[tokenId];
        // Lease complete if expired
        return info.expires > 0 && block.timestamp > info.expires;
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
                // Don't block operations if credential fails
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
