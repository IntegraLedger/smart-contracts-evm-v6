// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IDocumentResolver.sol";
import "../layer0/AttestationAccessControlV6.sol";

/**
 * @title MultiPartyResolverV6Lite
 * @notice ERC-6909 resolver for gas-efficient multi-stakeholder documents
 *
 * V6 ARCHITECTURE:
 * - Anonymous reservations (address unknown at reservation time)
 * - Encrypted labels for role identification
 * - Attestation-based access control (no ZK proofs)
 * - Simplified two-step workflow (reserve → claim)
 * - 50% cheaper gas than ERC-1155
 *
 * TOKEN ID SEMANTICS:
 * Token IDs represent roles: 1: Buyer, 2: Seller, 3: Tenant, etc.
 *
 * USE CASES:
 * - High-volume multi-party documents (cheaper than ERC-1155)
 * - Purchase agreements (buyer + seller)
 * - Lease contracts (tenant + landlord + guarantor)
 * - Partnership agreements (multiple partners)
 * - Multi-party legal contracts
 *
 * ERC-6909 ADVANTAGES:
 * - No mandatory callbacks (50% gas savings)
 * - Hybrid approval system (operator + allowance)
 * - Custom batch implementation (optimize for use case)
 * - Used by Uniswap V4 (battle-tested)
 *
 * WORKFLOW:
 * 1. Issuer reserves tokens with encrypted labels (addresses unknown)
 * 2. Parties verify identity off-chain
 * 3. Issuer issues capability attestations via EAS
 * 4. Parties claim tokens using attestations
 */
contract MultiPartyResolverV6Lite is
    AttestationAccessControlV6,
    IDocumentResolver
{
    // ============ Constants ============

    uint256 public constant MAX_ENCRYPTED_LABEL_LENGTH = 500;
    uint256 public constant MAX_TOKENS_PER_DOCUMENT = 100;

    // ============ ERC-6909 Interface ID ============

    bytes4 private constant _INTERFACE_ID_ERC6909 = 0x0f632fb3;

    // ============ State Variables ============

    struct TokenData {
        bytes32 integraHash;                    // Document identifier
        uint256 totalSupply;                    // Total minted tokens
        uint256 reservedAmount;                 // Reserved but not minted
        bytes encryptedLabel;                   // Role label
        address reservedFor;                    // Specific address (or address(0))
        bool claimed;                           // Whether claimed
        address claimedBy;                      // Who claimed
        address[] holders;                      // Current holders
        mapping(address => bool) isHolder;      // Quick holder lookup
    }

    /// @notice Token data: integraHash → tokenId → TokenData
    mapping(bytes32 => mapping(uint256 => TokenData)) private tokenData;

    /// @notice ERC-6909 balances: owner → id → balance
    mapping(address => mapping(uint256 => uint256)) private _balances;

    /// @notice ERC-6909 allowances: owner → spender → id → amount
    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;

    /// @notice ERC-6909 operators: owner → operator → approved
    mapping(address => mapping(address => bool)) public isOperator;

    /// @notice Base URI for metadata
    string private _baseURI;

    // ============ Trust Graph Integration ============

    mapping(bytes32 => address[]) private documentParties;
    mapping(bytes32 => bool) private credentialsIssued;
    address public trustRegistry;
    bytes32 public credentialSchema;

    // ============ Events ============

    // ERC-6909 events
    event Transfer(
        address indexed caller,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 amount
    );

    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 indexed id,
        uint256 amount
    );

    event OperatorSet(
        address indexed owner,
        address indexed operator,
        bool approved
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
    error InsufficientBalance(address owner, uint256 id, uint256 balance, uint256 amount);
    error InsufficientPermission(address caller, address owner, uint256 id);
    error EncryptedLabelTooLarge(uint256 length, uint256 maximum);

    // ============ Constructor & Initialization ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
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

        _baseURI = baseURI_;

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
        if (amount == 0) revert InvalidAmount(amount);

        TokenData storage data = tokenData[integraHash][tokenId];

        if (data.integraHash != bytes32(0)) {
            revert TokenAlreadyReserved(integraHash, tokenId);
        }

        data.integraHash = integraHash;
        data.reservedAmount = amount;
        data.reservedFor = recipient;
        data.claimed = false;

        emit IDocumentResolver.TokenReserved(integraHash, tokenId, recipient, amount, block.timestamp);
    }

    function reserveTokenAnonymous(
        address caller,
        bytes32 integraHash,
        uint256 tokenId,
        uint256 amount,
        bytes calldata encryptedLabel
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount(amount);

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
        data.reservedFor = address(0);
        data.claimed = false;

        emit IDocumentResolver.TokenReservedAnonymous(integraHash, tokenId, amount, encryptedLabel, block.timestamp);
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
        TokenData storage data = tokenData[integraHash][tokenId];

        if (data.integraHash == bytes32(0)) {
            revert TokenNotReserved(integraHash, tokenId);
        }

        if (data.claimed) {
            revert TokenAlreadyClaimed(integraHash, tokenId);
        }

        if (data.reservedFor != address(0) && data.reservedFor != msg.sender) {
            revert NotReservedForYou(msg.sender, data.reservedFor);
        }

        // Mint tokens (ERC-6909 style)
        _balances[msg.sender][tokenId] += data.reservedAmount;

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

        emit IDocumentResolver.TokenClaimed(integraHash, tokenId, msg.sender, capabilityAttestationUID, block.timestamp);
        emit Transfer(msg.sender, address(0), msg.sender, tokenId, data.totalSupply);

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

        TokenData storage data = tokenData[integraHash][tokenId];

        if (data.integraHash == bytes32(0)) {
            revert TokenNotReserved(integraHash, tokenId);
        }

        if (data.claimed) {
            revert TokenAlreadyClaimed(integraHash, tokenId);
        }

        uint256 cancelledAmount = data.reservedAmount;

        delete tokenData[integraHash][tokenId];

        emit IDocumentResolver.ReservationCancelled(integraHash, tokenId, cancelledAmount, block.timestamp);
    }

    // ============ ERC-6909 Interface ============

    /**
     * @notice Transfer tokens
     * @param receiver Recipient address
     * @param id Token ID
     * @param amount Amount to transfer
     */
    function transfer(
        address receiver,
        uint256 id,
        uint256 amount
    ) external returns (bool) {
        if (receiver == address(0)) revert ZeroAddress();

        uint256 senderBalance = _balances[msg.sender][id];
        if (senderBalance < amount) {
            revert InsufficientBalance(msg.sender, id, senderBalance, amount);
        }

        _balances[msg.sender][id] = senderBalance - amount;
        _balances[receiver][id] += amount;

        emit Transfer(msg.sender, msg.sender, receiver, id, amount);

        return true;
    }

    /**
     * @notice Transfer tokens from owner
     * @param sender Owner address
     * @param receiver Recipient address
     * @param id Token ID
     * @param amount Amount to transfer
     */
    function transferFrom(
        address sender,
        address receiver,
        uint256 id,
        uint256 amount
    ) external returns (bool) {
        if (receiver == address(0)) revert ZeroAddress();

        // Check permission (operator or sufficient allowance)
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowance[sender][msg.sender][id];
            if (allowed < amount) {
                revert InsufficientPermission(msg.sender, sender, id);
            }
            if (allowed != type(uint256).max) {
                allowance[sender][msg.sender][id] = allowed - amount;
            }
        }

        uint256 senderBalance = _balances[sender][id];
        if (senderBalance < amount) {
            revert InsufficientBalance(sender, id, senderBalance, amount);
        }

        _balances[sender][id] = senderBalance - amount;
        _balances[receiver][id] += amount;

        emit Transfer(msg.sender, sender, receiver, id, amount);

        return true;
    }

    /**
     * @notice Approve spender for specific token ID
     * @param spender Approved address
     * @param id Token ID
     * @param amount Approved amount (uint256.max for infinite)
     */
    function approve(
        address spender,
        uint256 id,
        uint256 amount
    ) external returns (bool) {
        allowance[msg.sender][spender][id] = amount;

        emit Approval(msg.sender, spender, id, amount);

        return true;
    }

    /**
     * @notice Set operator approval for all tokens
     * @param operator Operator address
     * @param approved Approval status
     */
    function setOperator(
        address operator,
        bool approved
    ) external returns (bool) {
        isOperator[msg.sender][operator] = approved;

        emit OperatorSet(msg.sender, operator, approved);

        return true;
    }

    // ============ View Functions ============

    function balanceOf(
        address account,
        uint256 tokenId
    ) public view returns (uint256) {
        return _balances[account][tokenId];
    }

    function getTokenInfo(
        bytes32 integraHash,
        uint256 tokenId
    ) external view returns (IDocumentResolver.TokenInfo memory) {
        TokenData storage data = tokenData[integraHash][tokenId];

        return IDocumentResolver.TokenInfo({
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

    function getEncryptedLabel(
        bytes32 integraHash,
        uint256 tokenId
    ) external view returns (bytes memory) {
        return tokenData[integraHash][tokenId].encryptedLabel;
    }

    function getAllEncryptedLabels(bytes32 integraHash)
        external
        view
        returns (uint256[] memory tokenIds, bytes[] memory labels)
    {
        // Count reserved tokens
        uint256 count = 0;
        for (uint256 i = 1; i <= 100; i++) {
            if (tokenData[integraHash][i].integraHash != bytes32(0)) {
                count++;
            }
        }

        // Build arrays
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

    function getReservedTokens(
        bytes32 integraHash,
        address recipient
    ) external view returns (uint256[] memory) {
        uint256 count = 0;
        for (uint256 i = 1; i <= 100; i++) {
            if (tokenData[integraHash][i].reservedFor == recipient) {
                count++;
            }
        }

        uint256[] memory reserved = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 1; i <= 100; i++) {
            if (tokenData[integraHash][i].reservedFor == recipient) {
                reserved[index++] = i;
            }
        }

        return reserved;
    }

    function getClaimStatus(bytes32 integraHash, uint256 tokenId)
        external
        view
        returns (bool claimed, address claimedBy)
    {
        TokenData storage data = tokenData[integraHash][tokenId];
        return (data.claimed, data.claimedBy);
    }

    function tokenType() external pure returns (IDocumentResolver.TokenType) {
        return IDocumentResolver.TokenType.CUSTOM;
    }

    /**
     * @notice Set base URI
     */
    function setURI(string memory newURI) external onlyRole(GOVERNOR_ROLE) {
        _baseURI = newURI;
    }

    /**
     * @notice Get token URI (simplified)
     */
    function uri(uint256 id) external view returns (string memory) {
        return _baseURI;
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
            interfaceId == _INTERFACE_ID_ERC6909 ||
            super.supportsInterface(interfaceId);
    }

    // ============ Trust Graph Integration ============

    function _handleTrustCredential(bytes32 integraHash, address party) internal {
        if (trustRegistry == address(0)) return;
        if (credentialsIssued[integraHash]) return;

        if (!_isPartyTracked(integraHash, party)) {
            documentParties[integraHash].push(party);
        }

        if (_isDocumentComplete(integraHash)) {
            _issueCredentialsToAllParties(integraHash);
        }
    }

    function _isDocumentComplete(bytes32 integraHash) internal view returns (bool) {
        for (uint256 i = 1; i <= 100; i++) {
            TokenData storage data = tokenData[integraHash][i];
            if (data.integraHash != bytes32(0) && data.reservedAmount > 0 && !data.claimed) {
                return false;
            }
        }
        return true;
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
