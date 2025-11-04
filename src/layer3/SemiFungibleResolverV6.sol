// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IDocumentResolver.sol";
import "../layer0/AttestationAccessControlV6.sol";

/**
 * @title SemiFungibleResolverV6
 * @notice ERC-3525 resolver for semi-fungible financial instruments
 *
 * V6 ARCHITECTURE:
 * - Anonymous reservations (address unknown at reservation time)
 * - Encrypted labels for instrument terms
 * - Attestation-based access control (no ZK proofs)
 * - Simplified two-step workflow (reserve → claim)
 * - ID + SLOT + VALUE model
 *
 * USE CASES:
 * - Bonds with different amounts (same series = same slot)
 * - Vesting plans with tranches (vesting schedule = slot)
 * - Insurance policies (policy type = slot, coverage = value)
 * - Mortgages & loans (loan terms = slot, principal = value)
 * - Invoice factoring (due date = slot, amount = value)
 * - Structured products (tranche = slot, investment = value)
 *
 * ERC-3525 MODEL:
 * - ID: Unique token identifier (like ERC-721)
 * - SLOT: Category/type (tokens with same slot are fungible)
 * - VALUE: Quantity (like ERC-20 balance)
 *
 * KEY FEATURE:
 * Tokens can split/merge within the same slot:
 * - Transfer partial VALUE from one token to another
 * - Same slot = fungible, different slots = unique
 *
 * WORKFLOW:
 * 1. Issuer reserves tokens in specific slot (bond series, vesting schedule)
 * 2. Investors verify identity off-chain
 * 3. Issuer issues capability attestations
 * 4. Investors claim tokens (receive ID with SLOT and VALUE)
 * 5. Can transfer partial VALUE to other tokens in same SLOT
 */
contract SemiFungibleResolverV6 is
    AttestationAccessControlV6,
    IDocumentResolver
{
    // ============ Constants ============

    uint256 public constant MAX_ENCRYPTED_LABEL_LENGTH = 500;

    // ============ ERC-3525 Interface IDs ============

    bytes4 private constant _INTERFACE_ID_ERC3525 = 0xd5358140;
    bytes4 private constant _INTERFACE_ID_ERC3525_SLOT_APPROVABLE = 0xb688be58;
    bytes4 private constant _INTERFACE_ID_ERC3525_SLOT_ENUMERABLE = 0x3b741b9e;

    // ============ State Variables ============

    struct TokenData {
        bytes32 integraHash;        // Document identifier
        uint256 slot;               // Slot identifier (determines fungibility)
        uint256 value;              // Token value (fungible within slot)
        address owner;              // Token owner
        bool minted;                // Whether token is minted
        address reservedFor;        // Reservation address
        bytes encryptedLabel;       // Token description
    }

    struct SlotData {
        bytes32 integraHash;        // Document this slot belongs to
        uint256 totalReserved;      // Reserved value in this slot
        uint256 totalMinted;        // Minted value in this slot
        bytes encryptedLabel;       // Slot description
        address[] holders;          // Holders in this slot
        mapping(address => bool) isHolder;
    }

    /// @notice Token data by tokenId (ID in ERC-3525)
    mapping(uint256 => TokenData) private _tokens;

    /// @notice Slot data by slot identifier
    mapping(uint256 => SlotData) private _slots;

    /// @notice Reverse mapping: integraHash → slot → tokenIds
    mapping(bytes32 => mapping(uint256 => uint256[])) private _documentSlotTokens;

    /// @notice ERC-3525 value approvals: tokenId → operator → amount
    mapping(uint256 => mapping(address => uint256)) private _valueApprovals;

    /// @notice Slot-level approvals: owner → slot → operator → approved
    mapping(address => mapping(uint256 => mapping(address => bool))) private _slotApprovals;

    /// @notice Token-level approvals (like ERC-721)
    mapping(uint256 => address) private _tokenApprovals;

    /// @notice Operator approvals (like ERC-721)
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    /// @notice Monotonic counter for tokenId generation
    uint256 private _nextTokenId;

    /// @notice Contract name
    string private _name;

    /// @notice Contract symbol
    string private _symbol;

    /// @notice Decimals for value
    uint8 private _valueDecimals;

    // ============ Trust Graph Integration ============

    mapping(bytes32 => address[]) private documentParties;
    mapping(bytes32 => bool) private credentialsIssued;
    address public trustRegistry;
    bytes32 public credentialSchema;

    // ============ Events ============

    // ERC-3525 events
    event TransferValue(
        uint256 indexed fromTokenId,
        uint256 indexed toTokenId,
        uint256 value
    );

    event ApprovalValue(
        uint256 indexed tokenId,
        address indexed operator,
        uint256 value
    );

    event SlotChanged(
        uint256 indexed tokenId,
        uint256 indexed oldSlot,
        uint256 indexed newSlot
    );

    // Standard events
    event Transfer(
        address indexed from,
        address indexed to,
        uint256 indexed tokenId
    );

    event Approval(
        address indexed owner,
        address indexed approved,
        uint256 indexed tokenId
    );

    event ApprovalForAll(
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

    error ZeroAddress();
    error InvalidTokenId(uint256 tokenId);
    error InvalidSlot(uint256 slot);
    error InvalidValue(uint256 value);
    error SlotMismatch(uint256 fromSlot, uint256 toSlot);
    error InsufficientValue(uint256 available, uint256 required);
    error InsufficientAllowance(uint256 allowed, uint256 required);
    error NotTokenOwner(address caller, address owner);
    error NotAuthorized(address caller);
    error TokenAlreadyReserved(bytes32 integraHash, uint256 slot);
    error OnlyIssuerCanCancel(address caller, address issuer);
    error EncryptedLabelTooLarge(uint256 length, uint256 maximum);

    // ============ Constructor & Initialization ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        uint8 valueDecimals_,
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
        _valueDecimals = valueDecimals_;
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

    /**
     * @notice Reserve tokens in a specific slot
     * @param integraHash Document identifier
     * @param tokenId Used as SLOT identifier for ERC-3525
     * @param recipient Recipient address
     * @param amount VALUE to reserve
     */
    function reserveToken(
        address caller,
        bytes32 integraHash,
        uint256 tokenId,
        address recipient,
        uint256 amount
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant whenNotPaused {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidValue(amount);

        uint256 slot = tokenId;  // tokenId maps to SLOT
        SlotData storage slotData = _slots[slot];

        if (slotData.integraHash == bytes32(0)) {
            slotData.integraHash = integraHash;
        }

        slotData.totalReserved += amount;

        // Create reservation token
        uint256 newTokenId = _nextTokenId++;

        _tokens[newTokenId] = TokenData({
            integraHash: integraHash,
            slot: slot,
            value: amount,
            owner: recipient,
            minted: false,
            reservedFor: recipient,
            encryptedLabel: ""
        });

        _documentSlotTokens[integraHash][slot].push(newTokenId);

        emit IDocumentResolver.TokenReserved(integraHash, newTokenId, recipient, amount, block.timestamp);
    }

    function reserveTokenAnonymous(
        address caller,
        bytes32 integraHash,
        uint256 tokenId,
        uint256 amount,
        bytes calldata encryptedLabel
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidValue(amount);

        if (encryptedLabel.length > MAX_ENCRYPTED_LABEL_LENGTH) {
            revert EncryptedLabelTooLarge(encryptedLabel.length, MAX_ENCRYPTED_LABEL_LENGTH);
        }

        uint256 slot = tokenId;  // tokenId maps to SLOT
        SlotData storage slotData = _slots[slot];

        if (slotData.integraHash == bytes32(0)) {
            slotData.integraHash = integraHash;
            slotData.encryptedLabel = encryptedLabel;
        }

        slotData.totalReserved += amount;

        emit IDocumentResolver.TokenReservedAnonymous(integraHash, slot, amount, encryptedLabel, block.timestamp);
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
        TokenData storage data = _tokens[tokenId];

        require(data.integraHash == integraHash, "Token not for this document");
        require(!data.minted, "Already minted");
        require(data.reservedFor == msg.sender || data.reservedFor == address(0), "Not reserved for you");

        // Mint token
        data.owner = msg.sender;
        data.minted = true;

        SlotData storage slotData = _slots[data.slot];
        slotData.totalMinted += data.value;
        slotData.totalReserved -= data.value;

        // Track holder
        if (!slotData.isHolder[msg.sender]) {
            slotData.holders.push(msg.sender);
            slotData.isHolder[msg.sender] = true;
        }

        emit IDocumentResolver.TokenClaimed(integraHash, tokenId, msg.sender, capabilityAttestationUID, block.timestamp);
        emit Transfer(address(0), msg.sender, tokenId);

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

        TokenData storage data = _tokens[tokenId];
        require(data.integraHash == integraHash, "Token not for this document");
        require(!data.minted, "Already minted");

        uint256 cancelledValue = data.value;
        uint256 slot = data.slot;

        _slots[slot].totalReserved -= cancelledValue;

        delete _tokens[tokenId];

        emit IDocumentResolver.ReservationCancelled(integraHash, tokenId, cancelledValue, block.timestamp);
    }

    // ============ ERC-3525 Core Functions ============

    /**
     * @notice Transfer value from one token to another (same slot)
     * @param fromTokenId Source token
     * @param toTokenId Destination token
     * @param value Amount to transfer
     */
    function transferFrom(
        uint256 fromTokenId,
        uint256 toTokenId,
        uint256 value
    ) external returns (uint256) {
        if (value == 0) revert InvalidValue(value);

        TokenData storage fromToken = _tokens[fromTokenId];
        TokenData storage toToken = _tokens[toTokenId];

        // Verify tokens exist and are in same slot
        if (fromToken.slot != toToken.slot) {
            revert SlotMismatch(fromToken.slot, toToken.slot);
        }

        // Check authorization
        _checkAuthorization(fromTokenId, msg.sender);

        // Check sufficient value
        if (fromToken.value < value) {
            revert InsufficientValue(fromToken.value, value);
        }

        // Transfer value
        fromToken.value -= value;
        toToken.value += value;

        emit TransferValue(fromTokenId, toTokenId, value);

        return toTokenId;
    }

    /**
     * @notice Transfer value from token to address (creates or finds token)
     * @param fromTokenId Source token
     * @param to Destination address
     * @param value Amount to transfer
     * @return toTokenId The destination token ID
     */
    function transferFrom(
        uint256 fromTokenId,
        address to,
        uint256 value
    ) external returns (uint256 toTokenId) {
        if (to == address(0)) revert ZeroAddress();
        if (value == 0) revert InvalidValue(value);

        TokenData storage fromToken = _tokens[fromTokenId];

        // Check authorization
        _checkAuthorization(fromTokenId, msg.sender);

        // Check sufficient value
        if (fromToken.value < value) {
            revert InsufficientValue(fromToken.value, value);
        }

        // Create new token for recipient in same slot
        toTokenId = _nextTokenId++;

        _tokens[toTokenId] = TokenData({
            integraHash: fromToken.integraHash,
            slot: fromToken.slot,
            value: value,
            owner: to,
            minted: true,
            reservedFor: address(0),
            encryptedLabel: fromToken.encryptedLabel
        });

        // Transfer value
        fromToken.value -= value;

        // Track holder
        SlotData storage slotData = _slots[fromToken.slot];
        if (!slotData.isHolder[to]) {
            slotData.holders.push(to);
            slotData.isHolder[to] = true;
        }

        emit TransferValue(fromTokenId, toTokenId, value);
        emit Transfer(address(0), to, toTokenId);

        return toTokenId;
    }

    /**
     * @notice Approve value spending
     * @param tokenId Token to approve
     * @param operator Approved address
     * @param value Approved amount
     */
    function approve(
        uint256 tokenId,
        address operator,
        uint256 value
    ) external {
        TokenData storage token = _tokens[tokenId];
        if (token.owner != msg.sender) {
            revert NotTokenOwner(msg.sender, token.owner);
        }

        _valueApprovals[tokenId][operator] = value;

        emit ApprovalValue(tokenId, operator, value);
    }

    /**
     * @notice Get value allowance
     * @param tokenId Token ID
     * @param operator Operator address
     * @return Approved value amount
     */
    function allowance(
        uint256 tokenId,
        address operator
    ) external view returns (uint256) {
        return _valueApprovals[tokenId][operator];
    }

    // ============ ERC-721 Compatibility ============

    /**
     * @notice Get token owner
     */
    function ownerOf(uint256 tokenId) public view returns (address) {
        return _tokens[tokenId].owner;
    }

    /**
     * @notice Approve token transfer (ERC-721 style)
     */
    function approve(address operator, uint256 tokenId) external {
        TokenData storage token = _tokens[tokenId];
        if (token.owner != msg.sender) {
            revert NotTokenOwner(msg.sender, token.owner);
        }

        _tokenApprovals[tokenId] = operator;

        emit Approval(msg.sender, operator, tokenId);
    }

    /**
     * @notice Set approval for all tokens (ERC-721 style)
     */
    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;

        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /**
     * @notice Get approved operator for token
     */
    function getApproved(uint256 tokenId) external view returns (address) {
        return _tokenApprovals[tokenId];
    }

    /**
     * @notice Check if operator is approved for all
     */
    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    // ============ ERC-3525 Specific Functions ============

    /**
     * @notice Get token value (balance)
     */
    function balanceOf(uint256 tokenId) external view returns (uint256) {
        return _tokens[tokenId].value;
    }

    /**
     * @notice Get token slot
     */
    function slotOf(uint256 tokenId) external view returns (uint256) {
        return _tokens[tokenId].slot;
    }

    /**
     * @notice Get value decimals
     */
    function valueDecimals() external view returns (uint8) {
        return _valueDecimals;
    }

    /**
     * @notice Approve operator for slot
     * @param slot Slot identifier
     * @param operator Operator address
     * @param approved Approval status
     */
    function setApprovalForSlot(
        address owner,
        uint256 slot,
        address operator,
        bool approved
    ) external {
        if (msg.sender != owner && !_operatorApprovals[owner][msg.sender]) {
            revert NotAuthorized(msg.sender);
        }

        _slotApprovals[owner][slot][operator] = approved;
    }

    /**
     * @notice Check slot-level approval
     */
    function isApprovedForSlot(
        address owner,
        uint256 slot,
        address operator
    ) external view returns (bool) {
        return _slotApprovals[owner][slot][operator];
    }

    // ============ IDocumentResolver View Functions ============

    function balanceOf(
        address account,
        uint256 tokenId
    ) public view returns (uint256) {
        if (_tokens[tokenId].owner == account && _tokens[tokenId].minted) {
            return _tokens[tokenId].value;
        }
        return 0;
    }

    function getTokenInfo(
        bytes32 integraHash,
        uint256 tokenId
    ) external view returns (IDocumentResolver.TokenInfo memory) {
        TokenData storage data = _tokens[tokenId];

        if (data.integraHash != integraHash) {
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

        SlotData storage slotData = _slots[data.slot];

        return IDocumentResolver.TokenInfo({
            integraHash: integraHash,
            tokenId: tokenId,
            totalSupply: slotData.totalMinted,
            reserved: slotData.totalReserved,
            holders: slotData.holders,
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
        return _tokens[tokenId].encryptedLabel;
    }

    function getAllEncryptedLabels(bytes32 integraHash)
        external
        view
        returns (uint256[] memory tokenIds, bytes[] memory labels)
    {
        // Scan slots 1-100 for this document
        uint256 count = 0;
        for (uint256 slot = 1; slot <= 100; slot++) {
            if (_slots[slot].integraHash == integraHash) {
                count++;
            }
        }

        tokenIds = new uint256[](count);
        labels = new bytes[](count);

        uint256 index = 0;
        for (uint256 slot = 1; slot <= 100; slot++) {
            if (_slots[slot].integraHash == integraHash) {
                tokenIds[index] = slot;
                labels[index] = _slots[slot].encryptedLabel;
                index++;
            }
        }

        return (tokenIds, labels);
    }

    function getReservedTokens(
        bytes32 integraHash,
        address recipient
    ) external view returns (uint256[] memory) {
        // Scan all tokens for this recipient
        uint256 count = 0;
        for (uint256 i = 1; i < _nextTokenId; i++) {
            if (_tokens[i].integraHash == integraHash &&
                _tokens[i].reservedFor == recipient &&
                !_tokens[i].minted) {
                count++;
            }
        }

        uint256[] memory reserved = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 1; i < _nextTokenId; i++) {
            if (_tokens[i].integraHash == integraHash &&
                _tokens[i].reservedFor == recipient &&
                !_tokens[i].minted) {
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
        TokenData storage data = _tokens[tokenId];
        if (data.integraHash != integraHash) {
            return (false, address(0));
        }
        return (data.minted, data.owner);
    }

    function tokenType() external pure returns (IDocumentResolver.TokenType) {
        return IDocumentResolver.TokenType.CUSTOM;
    }

    // ============ Metadata ============

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    // ============ Internal Helpers ============

    function _checkAuthorization(uint256 tokenId, address operator) internal view {
        TokenData storage token = _tokens[tokenId];

        // Owner always authorized
        if (token.owner == operator) return;

        // Check operator approval
        if (_operatorApprovals[token.owner][operator]) return;

        // Check token approval
        if (_tokenApprovals[tokenId] == operator) return;

        // Check slot approval
        if (_slotApprovals[token.owner][token.slot][operator]) return;

        // Check value approval
        if (_valueApprovals[tokenId][operator] > 0) return;

        revert NotAuthorized(operator);
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
            interfaceId == _INTERFACE_ID_ERC3525 ||
            interfaceId == _INTERFACE_ID_ERC3525_SLOT_APPROVABLE ||
            interfaceId == _INTERFACE_ID_ERC3525_SLOT_ENUMERABLE ||
            interfaceId == 0x80ac58cd ||  // ERC-721
            interfaceId == 0x5b5e139f ||  // ERC-721 Metadata
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
        // Check all slots for this document
        for (uint256 slot = 1; slot <= 100; slot++) {
            if (_slots[slot].integraHash == integraHash && _slots[slot].totalReserved > 0) {
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
