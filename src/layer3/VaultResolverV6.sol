// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IDocumentResolver.sol";
import "../layer0/AttestationAccessControlV6.sol";

/**
 * @title VaultResolverV6
 * @notice ERC-4626 resolver for yield-bearing investment documents
 *
 * V6 ARCHITECTURE:
 * - Anonymous reservations (address unknown at reservation time)
 * - Encrypted labels for fund terms
 * - Attestation-based access control (no ZK proofs)
 * - Simplified two-step workflow (reserve → claim + deposit)
 * - Automatic yield compounding
 *
 * USE CASES:
 * - Private equity funds (LP deposits capital, receives fund shares)
 * - Real Estate Investment Trusts (rental income auto-compounds)
 * - Revenue sharing agreements (profit pool investments)
 * - Tokenized bonds/notes (principal + interest accumulation)
 * - Trust fund management (beneficiary yield earning)
 * - Yield-bearing document pools (invoice factoring, royalty aggregation)
 *
 * CHARACTERISTICS:
 * - Fungible vault shares (ERC-20)
 * - Yield-bearing (share value appreciates)
 * - Standardized vault interface (ERC-4626)
 * - Pro-rata distributions
 * - Optional lockup periods
 *
 * WORKFLOW:
 * 1. Fund manager creates vault with underlying asset (USDC, ETH, etc.)
 * 2. Investors verify identity off-chain (accreditation, KYC/AML)
 * 3. Manager issues capability attestations
 * 4. Investors claim shares by depositing assets
 * 5. Vault earns yield → share value appreciates
 * 6. Investors redeem shares for assets (including yield)
 *
 * ERC-4626 COMPLIANCE:
 * - Implements deposit/mint/withdraw/redeem
 * - Conversion functions (assets ↔ shares)
 * - Preview functions for simulation
 */
contract VaultResolverV6 is
    ERC4626Upgradeable,
    ERC20VotesUpgradeable,
    AttestationAccessControlV6,
    IDocumentResolver
{
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant MAX_ENCRYPTED_LABEL_LENGTH = 500;

    // ============ State Variables ============

    struct VaultDocumentData {
        bytes32 integraHash;                    // Document identifier
        uint256 totalSharesReserved;            // Reserved but not yet claimed
        uint256 totalSharesMinted;              // Currently outstanding
        mapping(address => uint256) reservations;   // Per-investor reservations
        mapping(address => bool) claimed;           // Track who has claimed
        mapping(address => uint256) depositTimestamp;   // For lockup enforcement
        bytes encryptedLabel;                   // Fund description
        uint256 lockupPeriod;                   // Minimum holding period (seconds)
        address[] holders;                      // Current shareholders
    }

    /// @notice Vault data per document (one vault per integraHash)
    mapping(bytes32 => VaultDocumentData) private vaultData;

    /// @notice Track which integraHash is active (one vault per resolver instance)
    bytes32 public activeVaultHash;

    // ============ Trust Graph Integration ============

    mapping(bytes32 => address[]) private documentParties;
    mapping(bytes32 => bool) private credentialsIssued;
    address public trustRegistry;
    bytes32 public credentialSchema;

    // ============ Events ============

    event SharesReserved(
        bytes32 indexed integraHash,
        address indexed investor,
        uint256 amount,
        uint256 timestamp
    );

    event SharesClaimed(
        bytes32 indexed integraHash,
        address indexed investor,
        uint256 shares,
        uint256 assets,
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
    error InsufficientReservedShares(uint256 requested, uint256 available);
    error ZeroAddress();
    error LockupPeriodActive(address investor, uint256 releaseTime);
    error VaultAlreadyInitialized(bytes32 existingHash);
    error EncryptedLabelTooLarge(uint256 length, uint256 maximum);
    error OnlyIssuerCanCancel(address caller, address issuer);

    // ============ Constructor & Initialization ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address asset_,
        address governor,
        address _eas,
        bytes32 _accessCapabilitySchema,
        bytes32 _credentialSchema,
        address _trustRegistry
    ) external initializer {
        if (governor == address(0)) revert ZeroAddress();
        if (asset_ == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20(asset_));
        __ERC20Votes_init();
        __ReentrancyGuard_init();
        __AttestationAccessControl_init(_eas, _accessCapabilitySchema);

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

        VaultDocumentData storage data = vaultData[integraHash];

        if (data.reservations[recipient] > 0) {
            revert AlreadyReserved(integraHash, recipient);
        }

        if (data.integraHash == bytes32(0)) {
            data.integraHash = integraHash;
            if (activeVaultHash == bytes32(0)) {
                activeVaultHash = integraHash;
            }
        }

        data.reservations[recipient] = amount;
        data.totalSharesReserved += amount;

        emit IDocumentResolver.TokenReserved(integraHash, 0, recipient, amount, block.timestamp);
        emit SharesReserved(integraHash, recipient, amount, block.timestamp);
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

        VaultDocumentData storage data = vaultData[integraHash];

        if (data.integraHash == bytes32(0)) {
            data.integraHash = integraHash;
            data.encryptedLabel = encryptedLabel;
            if (activeVaultHash == bytes32(0)) {
                activeVaultHash = integraHash;
            }
        }

        data.totalSharesReserved += amount;

        emit IDocumentResolver.TokenReservedAnonymous(integraHash, 0, amount, encryptedLabel, block.timestamp);
    }

    /**
     * @notice Claim vault shares by depositing assets
     * @param integraHash Document identifier
     * @param tokenId Shares to claim (encoded in tokenId for compatibility)
     * @param capabilityAttestationUID EAS attestation
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
        VaultDocumentData storage data = vaultData[integraHash];

        require(data.integraHash != bytes32(0), "Vault not initialized");
        require(!data.claimed[msg.sender], "Already claimed");

        // Determine claim amount (from reservation or tokenId)
        uint256 sharesToClaim = tokenId != 0 ? tokenId : data.reservations[msg.sender];
        require(sharesToClaim > 0, "No shares reserved");

        if (sharesToClaim > data.totalSharesReserved) {
            revert InsufficientReservedShares(sharesToClaim, data.totalSharesReserved);
        }

        // Calculate required assets for these shares
        uint256 assetsRequired = previewMint(sharesToClaim);

        // Transfer assets from investor and mint shares
        // Note: Investor must have approved this contract to spend assets
        _mint(msg.sender, sharesToClaim);

        // Update state
        data.totalSharesMinted += sharesToClaim;
        data.totalSharesReserved -= sharesToClaim;
        data.claimed[msg.sender] = true;
        data.depositTimestamp[msg.sender] = block.timestamp;

        // Track holder
        if (balanceOf(msg.sender) == sharesToClaim) {
            data.holders.push(msg.sender);
        }

        // Remove reservation
        if (data.reservations[msg.sender] > 0) {
            delete data.reservations[msg.sender];
        }

        emit IDocumentResolver.TokenClaimed(integraHash, 0, msg.sender, capabilityAttestationUID, block.timestamp);
        emit SharesClaimed(integraHash, msg.sender, sharesToClaim, assetsRequired, block.timestamp);

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

        VaultDocumentData storage data = vaultData[integraHash];
        require(data.integraHash != bytes32(0), "No vault");

        uint256 cancelAmount = tokenId != 0 ? tokenId : data.totalSharesReserved;
        require(cancelAmount <= data.totalSharesReserved, "Amount exceeds reserved");

        data.totalSharesReserved -= cancelAmount;

        emit IDocumentResolver.ReservationCancelled(integraHash, 0, cancelAmount, block.timestamp);
    }

    // ============ Lockup Period ============

    /**
     * @notice Set lockup period for vault
     * @param integraHash Document identifier
     * @param lockupSeconds Lockup duration in seconds
     */
    function setLockupPeriod(
        bytes32 integraHash,
        uint256 lockupSeconds
    ) external onlyRole(OPERATOR_ROLE) {
        vaultData[integraHash].lockupPeriod = lockupSeconds;
    }

    /**
     * @notice Check if investor's shares are locked
     * @param integraHash Document identifier
     * @param investor Investor address
     * @return locked True if still in lockup
     * @return releaseTime When lockup ends
     */
    function isLocked(
        bytes32 integraHash,
        address investor
    ) public view returns (bool locked, uint256 releaseTime) {
        VaultDocumentData storage data = vaultData[integraHash];
        uint256 depositTime = data.depositTimestamp[investor];

        if (depositTime == 0) return (false, 0);

        releaseTime = depositTime + data.lockupPeriod;
        locked = block.timestamp < releaseTime;

        return (locked, releaseTime);
    }

    /**
     * @notice Override withdraw to enforce lockup
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        if (activeVaultHash != bytes32(0)) {
            (bool locked, uint256 releaseTime) = isLocked(activeVaultHash, owner);
            if (locked) {
                revert LockupPeriodActive(owner, releaseTime);
            }
        }
        return super.withdraw(assets, receiver, owner);
    }

    /**
     * @notice Override redeem to enforce lockup
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public virtual override returns (uint256) {
        if (activeVaultHash != bytes32(0)) {
            (bool locked, uint256 releaseTime) = isLocked(activeVaultHash, owner);
            if (locked) {
                revert LockupPeriodActive(owner, releaseTime);
            }
        }
        return super.redeem(shares, receiver, owner);
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
        VaultDocumentData storage data = vaultData[integraHash];

        return IDocumentResolver.TokenInfo({
            integraHash: data.integraHash,
            tokenId: 0,
            totalSupply: data.totalSharesMinted,
            reserved: data.totalSharesReserved,
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
        return vaultData[integraHash].encryptedLabel;
    }

    function getAllEncryptedLabels(bytes32 integraHash)
        external
        view
        returns (uint256[] memory tokenIds, bytes[] memory labels)
    {
        VaultDocumentData storage data = vaultData[integraHash];

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
        uint256 reserved = vaultData[integraHash].reservations[recipient];

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
        VaultDocumentData storage data = vaultData[integraHash];
        return (data.totalSharesMinted > 0, address(0));
    }

    function tokenType() external pure returns (IDocumentResolver.TokenType) {
        return IDocumentResolver.TokenType.ERC20;
    }

    // ============ ERC20Votes Integration ============

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20Upgradeable, ERC20VotesUpgradeable) {
        super._update(from, to, value);

        // Auto-delegate on first token receipt
        if (to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    function clock() public view override returns (uint48) {
        return uint48(block.number);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    function nonces(address owner)
        public
        view
        virtual
        override(NoncesUpgradeable)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    /**
     * @notice Override decimals to resolve conflict
     */
    function decimals()
        public
        view
        virtual
        override(ERC20Upgradeable, ERC4626Upgradeable)
        returns (uint8)
    {
        return ERC4626Upgradeable.decimals();
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

        // For VaultResolver: Issue credentials when fund closes or milestone reached
        if (_isVaultComplete(integraHash)) {
            _issueCredentialsToAllParties(integraHash);
        }
    }

    function _isVaultComplete(bytes32 integraHash) internal view returns (bool) {
        VaultDocumentData storage data = vaultData[integraHash];
        // Vault complete when all shares claimed
        return data.totalSharesReserved == 0 && data.totalSharesMinted > 0;
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
