// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IDocumentResolver.sol";
import "../layer0/AttestationAccessControlV6.sol";

/**
 * @title RoyaltyResolverV6
 * @notice ERC-721 + ERC-2981 resolver for assets with creator royalties
 *
 * V6 ARCHITECTURE:
 * - Anonymous reservations (address unknown at reservation time)
 * - Encrypted labels for asset metadata
 * - Attestation-based access control (no ZK proofs)
 * - Simplified two-step workflow (reserve → claim)
 * - Creator royalties on secondary sales
 *
 * USE CASES:
 * - Intellectual property licensing (patent royalties)
 * - Creative works (digital art, music composition, photography)
 * - Revenue rights documents (product royalties, film residuals)
 * - Real estate appreciation sharing (developer gets % of resales)
 * - Business sale earnouts (seller gets % of future sales)
 * - Securitized assets (servicing fees on secondary market)
 *
 * CHARACTERISTICS:
 * - One NFT per asset
 * - Transferable (standard ERC-721 transfers)
 * - Royalty payments on each transfer
 * - Configurable royalty percentage per document
 *
 * WORKFLOW:
 * 1. Creator reserves NFT with royalty configuration (address unknown)
 * 2. Buyer verifies purchase off-chain
 * 3. Creator issues capability attestation via EAS
 * 4. Buyer claims NFT (pays initial price to creator)
 * 5. On resale: Marketplace queries royaltyInfo() and pays creator
 *
 * ERC-2981 COMPLIANCE:
 * - Implements royaltyInfo() for marketplace integration
 * - Percentage-based royalty calculations
 * - Configurable per token
 * - Optional tiered royalties
 */
contract RoyaltyResolverV6 is
    ERC721Upgradeable,
    ERC2981Upgradeable,
    AttestationAccessControlV6,
    IDocumentResolver
{
    // ============ Constants ============

    uint256 public constant MAX_ENCRYPTED_LABEL_LENGTH = 500;
    uint256 public constant MAX_TOKENS_PER_DOCUMENT = 100;
    uint96 public constant MAX_ROYALTY_PERCENTAGE = 10000;  // 100% in basis points

    // ============ State Variables ============

    struct RoyaltyTokenData {
        bytes32 integraHash;            // Document identifier
        address owner;                  // Current owner
        bool minted;                    // Prevents double minting
        address reservedFor;            // Specific address (or address(0) for anonymous)
        bytes encryptedLabel;           // Asset description

        // Royalty configuration
        address royaltyRecipient;       // Who receives royalties
        uint96 royaltyPercentage;       // Basis points (10000 = 100%)
        uint256 royaltyCapAmount;       // Optional cap (0 = no cap)

        // Transfer tracking
        uint256 transferCount;          // Number of times transferred
    }

    struct RoyaltyTier {
        uint256 maxTransfers;           // Transfer count threshold
        uint96 royaltyPercentage;       // Royalty % for this tier
    }

    /// @notice Token data by tokenId
    mapping(uint256 => RoyaltyTokenData) private tokenData;

    /// @notice Reverse mapping: integraHash → tokenId
    mapping(bytes32 => uint256) public integraHashToTokenId;

    /// @notice Optional tiered royalties per token
    mapping(uint256 => RoyaltyTier[]) private royaltyTiers;

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

    event TokenMinted(
        bytes32 indexed integraHash,
        uint256 indexed tokenId,
        address indexed owner,
        uint256 timestamp
    );

    event RoyaltyConfigured(
        uint256 indexed tokenId,
        address indexed recipient,
        uint96 percentage,
        uint256 timestamp
    );

    event RoyaltyPaid(
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 amount,
        uint256 salePrice,
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
    error InvalidRoyaltyPercentage(uint96 percentage);
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
        __ERC2981_init();
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

        tokenData[newTokenId] = RoyaltyTokenData({
            integraHash: integraHash,
            owner: address(0),
            minted: false,
            reservedFor: recipient,
            encryptedLabel: "",
            royaltyRecipient: address(0),
            royaltyPercentage: 0,
            royaltyCapAmount: 0,
            transferCount: 0
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

        tokenData[newTokenId] = RoyaltyTokenData({
            integraHash: integraHash,
            owner: address(0),
            minted: false,
            reservedFor: address(0),
            encryptedLabel: encryptedLabel,
            royaltyRecipient: address(0),
            royaltyPercentage: 0,
            royaltyCapAmount: 0,
            transferCount: 0
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

        RoyaltyTokenData storage data = tokenData[actualTokenId];

        if (data.minted) {
            revert AlreadyMinted(actualTokenId);
        }

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

        RoyaltyTokenData storage data = tokenData[actualTokenId];

        if (data.minted) {
            revert AlreadyMinted(actualTokenId);
        }

        delete tokenData[actualTokenId];
        delete integraHashToTokenId[integraHash];

        emit IDocumentResolver.ReservationCancelled(integraHash, actualTokenId, 1, block.timestamp);
    }

    // ============ Royalty Configuration ============

    /**
     * @notice Set default royalty for token
     * @param integraHash Document identifier
     * @param recipient Royalty recipient address
     * @param feeNumerator Royalty percentage in basis points (500 = 5%)
     */
    function setTokenRoyalty(
        bytes32 integraHash,
        address recipient,
        uint96 feeNumerator
    ) external onlyRole(OPERATOR_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        if (feeNumerator > MAX_ROYALTY_PERCENTAGE) {
            revert InvalidRoyaltyPercentage(feeNumerator);
        }

        uint256 tokenId = integraHashToTokenId[integraHash];
        if (tokenId == 0) revert TokenNotFound(integraHash, 0);

        RoyaltyTokenData storage data = tokenData[tokenId];
        data.royaltyRecipient = recipient;
        data.royaltyPercentage = feeNumerator;

        // Set ERC-2981 royalty info
        _setTokenRoyalty(tokenId, recipient, feeNumerator);

        emit RoyaltyConfigured(tokenId, recipient, feeNumerator, block.timestamp);
    }

    /**
     * @notice Set royalty cap (maximum payment regardless of price)
     * @param integraHash Document identifier
     * @param capAmount Maximum royalty amount (0 = no cap)
     */
    function setRoyaltyCap(
        bytes32 integraHash,
        uint256 capAmount
    ) external onlyRole(OPERATOR_ROLE) {
        uint256 tokenId = integraHashToTokenId[integraHash];
        if (tokenId == 0) revert TokenNotFound(integraHash, 0);

        tokenData[tokenId].royaltyCapAmount = capAmount;
    }

    /**
     * @notice Set tiered royalties (percentage varies by transfer count)
     * @param integraHash Document identifier
     * @param tiers Array of royalty tiers
     */
    function setRoyaltyTiers(
        bytes32 integraHash,
        RoyaltyTier[] calldata tiers
    ) external onlyRole(OPERATOR_ROLE) {
        uint256 tokenId = integraHashToTokenId[integraHash];
        if (tokenId == 0) revert TokenNotFound(integraHash, 0);

        // Clear existing tiers
        delete royaltyTiers[tokenId];

        // Set new tiers
        for (uint256 i = 0; i < tiers.length; i++) {
            if (tiers[i].royaltyPercentage > MAX_ROYALTY_PERCENTAGE) {
                revert InvalidRoyaltyPercentage(tiers[i].royaltyPercentage);
            }
            royaltyTiers[tokenId].push(tiers[i]);
        }
    }

    // ============ ERC-2981 Override ============

    /**
     * @notice Get royalty info (ERC-2981 interface)
     * @param tokenId Token ID
     * @param salePrice Sale price
     * @return receiver Royalty recipient
     * @return royaltyAmount Royalty payment amount
     */
    function royaltyInfo(
        uint256 tokenId,
        uint256 salePrice
    ) public view virtual override returns (address receiver, uint256 royaltyAmount) {
        RoyaltyTokenData storage data = tokenData[tokenId];

        if (data.royaltyRecipient == address(0)) {
            return (address(0), 0);
        }

        // Get applicable royalty percentage (considering tiers)
        uint96 percentage = _getRoyaltyPercentage(tokenId, data.transferCount);

        // Calculate royalty amount
        royaltyAmount = (salePrice * percentage) / 10000;

        // Apply cap if configured
        if (data.royaltyCapAmount > 0 && royaltyAmount > data.royaltyCapAmount) {
            royaltyAmount = data.royaltyCapAmount;
        }

        return (data.royaltyRecipient, royaltyAmount);
    }

    /**
     * @notice Get applicable royalty percentage based on transfer count
     */
    function _getRoyaltyPercentage(uint256 tokenId, uint256 transferCount) internal view returns (uint96) {
        RoyaltyTier[] storage tiers = royaltyTiers[tokenId];

        // No tiers = use default percentage
        if (tiers.length == 0) {
            return tokenData[tokenId].royaltyPercentage;
        }

        // Find applicable tier
        for (uint256 i = 0; i < tiers.length; i++) {
            if (transferCount < tiers[i].maxTransfers) {
                return tiers[i].royaltyPercentage;
            }
        }

        // Beyond all tiers = use last tier percentage
        return tiers[tiers.length - 1].royaltyPercentage;
    }

    // ============ Transfer Tracking ============

    /**
     * @notice Override _update to track transfers
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);

        // Track transfers (not minting or burning)
        if (from != address(0) && to != address(0)) {
            tokenData[tokenId].transferCount++;
        }

        // Update owner
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

        RoyaltyTokenData storage data = tokenData[actualTokenId];

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

        RoyaltyTokenData storage data = tokenData[tokenId];

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

        RoyaltyTokenData storage data = tokenData[actualTokenId];
        return (data.minted, data.owner);
    }

    function tokenType() external pure returns (IDocumentResolver.TokenType) {
        return IDocumentResolver.TokenType.ERC721;
    }

    /**
     * @notice Get royalty configuration for token
     */
    function getRoyaltyConfig(uint256 tokenId)
        external
        view
        returns (
            address recipient,
            uint96 percentage,
            uint256 capAmount,
            uint256 transferCount
        )
    {
        RoyaltyTokenData storage data = tokenData[tokenId];
        return (
            data.royaltyRecipient,
            data.royaltyPercentage,
            data.royaltyCapAmount,
            data.transferCount
        );
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
    ) public view override(ERC721Upgradeable, ERC2981Upgradeable, AccessControlUpgradeable) returns (bool) {
        return
            interfaceId == type(IDocumentResolver).interfaceId ||
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
