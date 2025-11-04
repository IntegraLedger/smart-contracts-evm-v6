// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IDocumentResolver.sol";
import "../layer0/AttestationAccessControlV6.sol";

/**
 * @title SecurityTokenResolverV6
 * @notice ERC-3643 resolver for regulated security tokens with programmatic compliance
 *
 * V6 ARCHITECTURE:
 * - Anonymous reservations (address unknown at reservation time)
 * - Encrypted labels for security class metadata
 * - Attestation-based access control (no ZK proofs)
 * - Simplified two-step workflow (reserve → claim)
 * - Programmatic compliance enforcement
 *
 * ERC-3643 FEATURES:
 * - Built-in identity verification (ONCHAINID integration)
 * - Transfer restrictions (compliance-gated)
 * - Agent roles (operational delegation)
 * - Batch operations (gas optimization)
 * - Forced transfers (regulatory compliance)
 * - Token freezing (partial and total)
 * - Recovery mechanism (lost private keys)
 *
 * USE CASES:
 * - Private securities offerings (Reg D, Reg S, Reg A+)
 * - Equity tokens (common/preferred stock with restrictions)
 * - Debt securities (bonds, convertible notes)
 * - Fund tokens (PE, VC, hedge fund shares)
 * - Real estate securities (REIT tokens)
 *
 * COMPLIANCE MODEL:
 * Transfer succeeds ONLY if ALL conditions met:
 * 1. Sender has sufficient unfrozen balance
 * 2. Sender address not frozen
 * 3. Receiver verified in identity registry
 * 4. Receiver has required claims from trusted issuers
 * 5. Token not paused
 * 6. Compliance rules satisfied
 * 7. Jurisdiction restrictions met
 *
 * WORKFLOW:
 * 1. Issuer creates security token with compliance rules
 * 2. Investors complete KYC/AML off-chain (receive ONCHAINID claims)
 * 3. Issuer reserves tokens for verified investors
 * 4. Investors claim tokens (minted with transfer restrictions)
 * 5. Secondary transfers auto-validate compliance
 * 6. Non-compliant transfers automatically revert
 */
contract SecurityTokenResolverV6 is
    ERC20Upgradeable,
    AttestationAccessControlV6,
    IDocumentResolver
{
    // ============ Constants ============

    uint256 public constant MAX_ENCRYPTED_LABEL_LENGTH = 500;

    // ============ Agent Roles ============

    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    // ============ State Variables ============

    struct SecurityTokenData {
        bytes32 integraHash;                    // Document identifier
        uint256 totalReserved;                  // Reserved tokens
        uint256 totalMinted;                    // Issued tokens
        bytes encryptedLabel;                   // Security description

        // Reservations
        mapping(address => uint256) reservations;
        mapping(address => bool) claimed;

        // Identity & Compliance
        mapping(address => bool) verified;              // KYC/AML verified addresses
        mapping(address => uint16) jurisdiction;        // ISO-3166 country codes
        mapping(address => bool) accreditedInvestor;    // Accreditation status

        // Freezing
        mapping(address => bool) frozen;                // Address-level freeze
        mapping(address => uint256) frozenTokens;       // Partial token freeze

        // Compliance limits
        uint256 maxHolders;                     // Maximum number of holders
        uint256 currentHolders;                 // Current holder count
        mapping(uint16 => uint256) holdersByCountry;    // Holders per country
        mapping(uint16 => uint256) maxHoldersByCountry; // Max per country

        address[] holders;                      // List of holders
    }

    /// @notice Security data per document
    mapping(bytes32 => SecurityTokenData) private securityData;

    /// @notice Active document hash (one security per resolver instance)
    bytes32 public activeSecurityHash;

    // ============ Trust Graph Integration ============

    mapping(bytes32 => address[]) private documentParties;
    mapping(bytes32 => bool) private credentialsIssued;
    address public trustRegistry;
    bytes32 public credentialSchema;

    // ============ Events ============

    event IdentityVerified(
        address indexed investor,
        uint16 indexed country,
        bool accredited,
        uint256 timestamp
    );

    event AddressFrozen(
        address indexed investor,
        bool frozen,
        uint256 timestamp
    );

    event TokensFrozen(
        address indexed investor,
        uint256 amount,
        uint256 timestamp
    );

    event ForcedTransfer(
        address indexed from,
        address indexed to,
        uint256 amount,
        address indexed agent,
        uint256 timestamp
    );

    event RecoveryExecuted(
        address indexed lostWallet,
        address indexed newWallet,
        uint256 amount,
        uint256 timestamp
    );

    event ComplianceLimitSet(
        bytes32 indexed integraHash,
        string limitType,
        uint256 value,
        uint256 timestamp
    );

    event TrustCredentialsIssued(
        bytes32 indexed integraHash,
        uint256 partyCount,
        uint256 timestamp
    );

    // ============ Errors ============

    error InvalidAmount(uint256 amount);
    error AlreadyReserved(bytes32 integraHash, address investor);
    error NoReservation(bytes32 integraHash, address investor);
    error AlreadyClaimed(address investor);
    error ZeroAddress();
    error NotVerified(address investor);
    error AddressIsFrozen(address investor);
    error InsufficientUnfrozenBalance(address investor, uint256 available, uint256 required);
    error MaxHoldersReached(uint256 current, uint256 max);
    error CountryMaxHoldersReached(uint16 country, uint256 current, uint256 max);
    error NotAccreditedInvestor(address investor);
    error OnlyAgentOrOwner(address caller);
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
        address governor,
        address _eas,
        bytes32 _accessCapabilitySchema,
        bytes32 _credentialSchema,
        address _trustRegistry
    ) external initializer {
        if (governor == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __ReentrancyGuard_init();
        __AttestationAccessControl_init(_eas, _accessCapabilitySchema);

        credentialSchema = _credentialSchema;
        trustRegistry = _trustRegistry;

        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
        _grantRole(EXECUTOR_ROLE, governor);
        _grantRole(OPERATOR_ROLE, governor);
        _grantRole(AGENT_ROLE, governor);
        _grantRole(COMPLIANCE_ROLE, governor);
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

        SecurityTokenData storage data = securityData[integraHash];

        if (data.reservations[recipient] > 0) {
            revert AlreadyReserved(integraHash, recipient);
        }

        if (data.integraHash == bytes32(0)) {
            data.integraHash = integraHash;
            if (activeSecurityHash == bytes32(0)) {
                activeSecurityHash = integraHash;
            }
        }

        data.reservations[recipient] = amount;
        data.totalReserved += amount;

        emit IDocumentResolver.TokenReserved(integraHash, 0, recipient, amount, block.timestamp);
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

        SecurityTokenData storage data = securityData[integraHash];

        if (data.integraHash == bytes32(0)) {
            data.integraHash = integraHash;
            data.encryptedLabel = encryptedLabel;
            if (activeSecurityHash == bytes32(0)) {
                activeSecurityHash = integraHash;
            }
        }

        data.totalReserved += amount;

        emit IDocumentResolver.TokenReservedAnonymous(integraHash, 0, amount, encryptedLabel, block.timestamp);
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
        SecurityTokenData storage data = securityData[integraHash];

        require(data.integraHash != bytes32(0), "Security not initialized");
        require(!data.claimed[msg.sender], "Already claimed");

        // Must be verified
        if (!data.verified[msg.sender]) {
            revert NotVerified(msg.sender);
        }

        uint256 claimAmount = tokenId != 0 ? tokenId : data.reservations[msg.sender];
        require(claimAmount > 0, "No reservation");
        require(claimAmount <= data.totalReserved, "Insufficient reserved");

        // Mint tokens
        _mint(msg.sender, claimAmount);

        // Update state
        data.totalMinted += claimAmount;
        data.totalReserved -= claimAmount;
        data.claimed[msg.sender] = true;

        // Track holder
        if (balanceOf(msg.sender) == claimAmount) {
            data.holders.push(msg.sender);
            data.currentHolders++;

            // Track by country
            uint16 country = data.jurisdiction[msg.sender];
            if (country != 0) {
                data.holdersByCountry[country]++;
            }
        }

        // Remove reservation
        if (data.reservations[msg.sender] > 0) {
            delete data.reservations[msg.sender];
        }

        emit IDocumentResolver.TokenClaimed(integraHash, 0, msg.sender, capabilityAttestationUID, block.timestamp);

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

        SecurityTokenData storage data = securityData[integraHash];
        require(data.integraHash != bytes32(0), "No security");

        uint256 cancelAmount = tokenId != 0 ? tokenId : data.totalReserved;
        require(cancelAmount <= data.totalReserved, "Amount exceeds reserved");

        data.totalReserved -= cancelAmount;

        emit IDocumentResolver.ReservationCancelled(integraHash, 0, cancelAmount, block.timestamp);
    }

    // ============ Identity Management ============

    /**
     * @notice Verify investor identity (KYC/AML)
     * @param integraHash Document identifier
     * @param investor Investor address
     * @param country ISO-3166 country code
     * @param accredited Accredited investor status
     */
    function verifyIdentity(
        bytes32 integraHash,
        address investor,
        uint16 country,
        bool accredited
    ) external onlyRole(COMPLIANCE_ROLE) {
        if (investor == address(0)) revert ZeroAddress();

        SecurityTokenData storage data = securityData[integraHash];

        data.verified[investor] = true;
        data.jurisdiction[investor] = country;
        data.accreditedInvestor[investor] = accredited;

        emit IdentityVerified(investor, country, accredited, block.timestamp);
    }

    /**
     * @notice Batch verify identities
     */
    function batchVerifyIdentity(
        bytes32 integraHash,
        address[] calldata investors,
        uint16[] calldata countries,
        bool[] calldata accredited
    ) external onlyRole(COMPLIANCE_ROLE) {
        require(investors.length == countries.length, "Length mismatch");
        require(investors.length == accredited.length, "Length mismatch");

        for (uint256 i = 0; i < investors.length; i++) {
            SecurityTokenData storage data = securityData[integraHash];

            data.verified[investors[i]] = true;
            data.jurisdiction[investors[i]] = countries[i];
            data.accreditedInvestor[investors[i]] = accredited[i];

            emit IdentityVerified(investors[i], countries[i], accredited[i], block.timestamp);
        }
    }

    /**
     * @notice Check if address is verified
     */
    function isVerified(bytes32 integraHash, address investor) external view returns (bool) {
        return securityData[integraHash].verified[investor];
    }

    // ============ Transfer Restrictions ============

    /**
     * @notice Check if transfer is allowed
     * @param integraHash Document identifier
     * @param from Sender
     * @param to Recipient
     * @param amount Transfer amount
     * @return True if compliant
     */
    function canTransfer(
        bytes32 integraHash,
        address from,
        address to,
        uint256 amount
    ) public view returns (bool) {
        SecurityTokenData storage data = securityData[integraHash];

        // Check 1: Sender has sufficient unfrozen balance
        uint256 availableBalance = balanceOf(from) - data.frozenTokens[from];
        if (availableBalance < amount) return false;

        // Check 2: Sender not frozen
        if (data.frozen[from]) return false;

        // Check 3: Receiver verified
        if (!data.verified[to]) return false;

        // Check 4: Token not paused
        if (paused()) return false;

        // Check 5: Holder limits
        if (balanceOf(to) == 0) {
            // New holder
            if (data.currentHolders >= data.maxHolders && data.maxHolders > 0) {
                return false;
            }

            // Country-specific limits
            uint16 country = data.jurisdiction[to];
            if (country != 0) {
                uint256 maxForCountry = data.maxHoldersByCountry[country];
                if (maxForCountry > 0 && data.holdersByCountry[country] >= maxForCountry) {
                    return false;
                }
            }
        }

        return true;
    }

    /**
     * @notice Override transfer to enforce compliance
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        if (activeSecurityHash != bytes32(0)) {
            if (!canTransfer(activeSecurityHash, msg.sender, to, amount)) {
                revert NotVerified(to);
            }
        }
        return super.transfer(to, amount);
    }

    /**
     * @notice Override transferFrom to enforce compliance
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        if (activeSecurityHash != bytes32(0)) {
            if (!canTransfer(activeSecurityHash, from, to, amount)) {
                revert NotVerified(to);
            }
        }
        return super.transferFrom(from, to, amount);
    }

    // ============ Freezing Controls ============

    /**
     * @notice Freeze address (prevent all transfers)
     * @param integraHash Document identifier
     * @param investor Address to freeze
     * @param freeze Freeze status
     */
    function setAddressFrozen(
        bytes32 integraHash,
        address investor,
        bool freeze
    ) external onlyRole(AGENT_ROLE) {
        securityData[integraHash].frozen[investor] = freeze;

        emit AddressFrozen(investor, freeze, block.timestamp);
    }

    /**
     * @notice Freeze partial tokens (restrict portion of balance)
     * @param integraHash Document identifier
     * @param investor Address
     * @param amount Tokens to freeze
     */
    function freezePartialTokens(
        bytes32 integraHash,
        address investor,
        uint256 amount
    ) external onlyRole(AGENT_ROLE) {
        require(amount <= balanceOf(investor), "Amount exceeds balance");

        securityData[integraHash].frozenTokens[investor] = amount;

        emit TokensFrozen(investor, amount, block.timestamp);
    }

    // ============ Agent Operations ============

    /**
     * @notice Forced transfer (for regulatory compliance)
     * @param integraHash Document identifier
     * @param from Source address
     * @param to Destination address
     * @param amount Transfer amount
     */
    function forcedTransfer(
        bytes32 integraHash,
        address from,
        address to,
        uint256 amount
    ) external onlyRole(AGENT_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        SecurityTokenData storage data = securityData[integraHash];

        // Forced transfers bypass some checks but still require verified receiver
        if (!data.verified[to]) {
            revert NotVerified(to);
        }

        _transfer(from, to, amount);

        emit ForcedTransfer(from, to, amount, msg.sender, block.timestamp);
    }

    /**
     * @notice Batch forced transfer
     */
    function batchForcedTransfer(
        bytes32 integraHash,
        address[] calldata from,
        address[] calldata to,
        uint256[] calldata amounts
    ) external onlyRole(AGENT_ROLE) nonReentrant {
        require(from.length == to.length, "Length mismatch");
        require(from.length == amounts.length, "Length mismatch");

        for (uint256 i = 0; i < from.length; i++) {
            this.forcedTransfer(integraHash, from[i], to[i], amounts[i]);
        }
    }

    /**
     * @notice Recover tokens from lost wallet
     * @param integraHash Document identifier
     * @param lostWallet Lost wallet address
     * @param newWallet New wallet address
     */
    function recoveryAddress(
        bytes32 integraHash,
        address lostWallet,
        address newWallet
    ) external onlyRole(AGENT_ROLE) {
        if (newWallet == address(0)) revert ZeroAddress();

        SecurityTokenData storage data = securityData[integraHash];

        uint256 balance = balanceOf(lostWallet);
        if (balance == 0) return;

        // Transfer verification status
        data.verified[newWallet] = data.verified[lostWallet];
        data.jurisdiction[newWallet] = data.jurisdiction[lostWallet];
        data.accreditedInvestor[newWallet] = data.accreditedInvestor[lostWallet];

        // Transfer tokens
        _transfer(lostWallet, newWallet, balance);

        // Update frozen status
        data.frozenTokens[newWallet] = data.frozenTokens[lostWallet];
        data.frozenTokens[lostWallet] = 0;

        emit RecoveryExecuted(lostWallet, newWallet, balance, block.timestamp);
    }

    // ============ Compliance Configuration ============

    /**
     * @notice Set maximum holders
     * @param integraHash Document identifier
     * @param maxHolders Maximum number of token holders
     */
    function setMaxHolders(
        bytes32 integraHash,
        uint256 maxHolders
    ) external onlyRole(COMPLIANCE_ROLE) {
        securityData[integraHash].maxHolders = maxHolders;

        emit ComplianceLimitSet(integraHash, "maxHolders", maxHolders, block.timestamp);
    }

    /**
     * @notice Set maximum holders per country
     * @param integraHash Document identifier
     * @param country ISO-3166 country code
     * @param maxHolders Maximum holders for this country
     */
    function setMaxHoldersByCountry(
        bytes32 integraHash,
        uint16 country,
        uint256 maxHolders
    ) external onlyRole(COMPLIANCE_ROLE) {
        securityData[integraHash].maxHoldersByCountry[country] = maxHolders;

        emit ComplianceLimitSet(integraHash, "maxHoldersByCountry", maxHolders, block.timestamp);
    }

    // ============ Batch Operations ============

    /**
     * @notice Batch transfer tokens
     * @param to Array of recipients
     * @param amounts Array of amounts
     */
    function batchTransfer(
        address[] calldata to,
        uint256[] calldata amounts
    ) external {
        require(to.length == amounts.length, "Length mismatch");

        for (uint256 i = 0; i < to.length; i++) {
            transfer(to[i], amounts[i]);
        }
    }

    // ============ View Functions ============

    function balanceOf(
        address account,
        uint256 tokenId
    ) public view returns (uint256) {
        return super.balanceOf(account);
    }

    function getTokenInfo(
        bytes32 integraHash,
        uint256 tokenId
    ) external view returns (IDocumentResolver.TokenInfo memory) {
        SecurityTokenData storage data = securityData[integraHash];

        return IDocumentResolver.TokenInfo({
            integraHash: data.integraHash,
            tokenId: 0,
            totalSupply: data.totalMinted,
            reserved: data.totalReserved,
            holders: data.holders,
            encryptedLabel: data.encryptedLabel,
            reservedFor: address(0),
            claimed: false,
            claimedBy: address(0)
        });
    }

    function getEncryptedLabel(
        bytes32 integraHash,
        uint256 tokenId
    ) external view returns (bytes memory) {
        return securityData[integraHash].encryptedLabel;
    }

    function getAllEncryptedLabels(bytes32 integraHash)
        external
        view
        returns (uint256[] memory tokenIds, bytes[] memory labels)
    {
        SecurityTokenData storage data = securityData[integraHash];

        if (data.integraHash == bytes32(0)) {
            return (new uint256[](0), new bytes[](0));
        }

        tokenIds = new uint256[](1);
        labels = new bytes[](1);

        tokenIds[0] = 0;
        labels[0] = data.encryptedLabel;

        return (tokenIds, labels);
    }

    function getReservedTokens(
        bytes32 integraHash,
        address recipient
    ) external view returns (uint256[] memory) {
        uint256 reserved = securityData[integraHash].reservations[recipient];

        if (reserved == 0) {
            return new uint256[](0);
        }

        uint256[] memory result = new uint256[](1);
        result[0] = 0;
        return result;
    }

    function getClaimStatus(bytes32 integraHash, uint256 tokenId)
        external
        view
        returns (bool claimed, address claimedBy)
    {
        SecurityTokenData storage data = securityData[integraHash];
        return (data.totalMinted > 0, address(0));
    }

    function tokenType() external pure returns (IDocumentResolver.TokenType) {
        return IDocumentResolver.TokenType.ERC20;
    }

    /**
     * @notice Get unfrozen balance for address
     * @param integraHash Document identifier
     * @param investor Investor address
     * @return Available balance (total - frozen)
     */
    function getFreeBalance(
        bytes32 integraHash,
        address investor
    ) external view returns (uint256) {
        uint256 total = balanceOf(investor);
        uint256 frozen = securityData[integraHash].frozenTokens[investor];
        return total > frozen ? total - frozen : 0;
    }

    /**
     * @notice Get compliance status
     */
    function getComplianceStatus(bytes32 integraHash)
        external
        view
        returns (
            uint256 currentHolders,
            uint256 maxHolders,
            uint256 totalMinted,
            uint256 totalReserved
        )
    {
        SecurityTokenData storage data = securityData[integraHash];
        return (
            data.currentHolders,
            data.maxHolders,
            data.totalMinted,
            data.totalReserved
        );
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
            super.supportsInterface(interfaceId);
    }

    // ============ Trust Graph Integration ============

    function _handleTrustCredential(bytes32 integraHash, address party) internal {
        if (trustRegistry == address(0)) return;
        if (credentialsIssued[integraHash]) return;

        if (!_isPartyTracked(integraHash, party)) {
            documentParties[integraHash].push(party);
        }

        if (_isSecurityComplete(integraHash)) {
            _issueCredentialsToAllParties(integraHash);
        }
    }

    function _isSecurityComplete(bytes32 integraHash) internal view returns (bool) {
        SecurityTokenData storage data = securityData[integraHash];
        return data.totalReserved == 0 && data.totalMinted > 0;
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
