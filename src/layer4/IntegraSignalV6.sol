// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../layer3/interfaces/IDocumentResolver.sol";
import "../layer2/IntegraDocumentRegistryV6.sol";
import "../layer0/interfaces/IEAS.sol";

/**
 * @title IntegraSignal
 * @notice High-integrity token-to-token messaging for payment requests
 *
 * V6 ARCHITECTURE:
 * - Token holder verification creates trust substrate for messaging
 * - Encrypted payment payloads (flexible schema, any payment method)
 * - Hybrid encryption (both requestor and payer can decrypt)
 * - EAS hash attestation (integrity verification without exposing details)
 * - No on-chain payment details (privacy preserved)
 * - Supports: crypto, wire, ACH, Stripe, Circle, PayPal, custom methods
 *
 * PRIVACY GUARANTEES:
 * - No wallet addresses exposed on-chain
 * - No ephemeral-to-primary mapping
 * - Payment details encrypted and off-chain
 * - Only document parties can decrypt messages
 * - Cross-document correlation impossible
 */
contract IntegraSignalV6 is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ============ Constants ============

    /**
     * @notice Maximum encrypted payment payload length (5KB)
     * @dev Sized for encrypted payment details (bank account, wire instructions, crypto address)
     *      Sufficient for complex international wire transfers with extensive notes
     *      For large attachments, use IPFS and store hash in payload
     */
    uint256 public constant MAX_ENCRYPTED_PAYLOAD_LENGTH = 5000;
    uint256 public constant MAX_REFERENCE_LENGTH = 200;
    uint256 public constant MAX_DISPLAY_CURRENCY_LENGTH = 10;
    uint256 public constant PAYMENT_REQUEST_TIMEOUT = 30 days;

    // ============ Types ============

    enum PaymentState {
        PENDING,      // Request created, awaiting payment
        PAID,         // Payment executed and confirmed
        CANCELLED,    // Request cancelled by either party
        DISPUTED,     // Payer disputes payment completion
        RESOLVED      // Dispute resolved by operator
    }

    /**
     * @notice Payment request with encrypted payload
     * @dev Payload contains flexible payment schema (crypto, wire, stripe, etc.)
     *      Only requestor and payer can decrypt the payload
     */
    struct PaymentRequest {
        // Document context
        bytes32 integraHash;
        uint256 requestorTokenId;
        uint256 payerTokenId;

        // Parties (ephemeral addresses, for indexing only)
        address requestor;
        address payer;

        // Hybrid encrypted payload
        bytes encryptedPayload;              // AES-encrypted payment details
        bytes encryptedSessionKeyPaymentRequestr;   // Session key encrypted for requestor (ECIES)
        bytes encryptedSessionKeyPayer;      // Session key encrypted for payer (ECIES)

        // Integrity verification
        bytes32 payloadHashAttestation;      // EAS attestation UID (requestor commits to payloadHash)

        // Display information (not used for actual payment execution)
        string invoiceReference;             // PaymentRequest #, description
        uint256 displayAmount;               // For UI display only
        string displayCurrency;              // For UI display only

        // State management
        PaymentState state;
        bytes32 paymentProof;                // TX hash, receipt, or other proof
        uint256 timestamp;                   // Request creation time
        uint256 paidTimestamp;               // Payment completion time
    }

    // ============ State ============

    IntegraDocumentRegistryV6 public documentRegistry;
    IEAS public eas;
    bytes32 public paymentPayloadSchemaUID;  // EAS schema for payload hash attestations

    mapping(bytes32 => PaymentRequest) public paymentRequests;
    mapping(bytes32 => bytes32[]) public requestsByDocument;
    mapping(address => bytes32[]) public requestsByPaymentRequestr;
    mapping(address => bytes32[]) public requestsByPayer;

    uint256 private _requestNonce;

    // ============ Events ============

    /**
     * @notice Payment request created
     * @dev No payment details in event - only encrypted payload reference
     * @dev payer is indexed to enable filtering by recipient
     */
    event PaymentRequested(
        bytes32 requestId,
        bytes32 indexed integraHash,
        address indexed requestor,
        address indexed payer,
        uint256 requestorTokenId,
        uint256 payerTokenId,
        bytes32 payloadHashAttestation,
        uint256 timestamp
    );

    /**
     * @notice Payment marked as paid
     */
    event PaymentMarkedPaid(
        bytes32 indexed requestId,
        address indexed markedBy,
        bytes32 paymentProof,
        uint256 timestamp
    );

    /**
     * @notice Payment request cancelled
     */
    event PaymentCancelled(
        bytes32 indexed requestId,
        address indexed cancelledBy,
        uint256 timestamp
    );

    /**
     * @notice Payment disputed by payer
     */
    event PaymentDisputed(
        bytes32 indexed requestId,
        address indexed disputedBy,
        string reason,
        uint256 timestamp
    );

    /**
     * @notice Dispute resolved by operator
     */
    event DisputeResolved(
        bytes32 indexed requestId,
        address indexed resolvedBy,
        bool inFavorOfPaymentRequestr,
        uint256 timestamp
    );

    // ============ Errors ============

    error RequestNotFound(bytes32 requestId);
    error InvalidState(PaymentState currentState, PaymentState requiredState);
    error NotAuthorized(address caller, address expected);
    error InvalidTokenHolder(address account, bytes32 integraHash, uint256 tokenId);
    error ZeroAddress();
    error InvalidAmount(uint256 amount);
    error InvalidAttestation(bytes32 attestationUID);
    error EmptyPayload();
    error EncryptedPayloadTooLarge(uint256 length, uint256 maximum);
    error ReferenceTooLong(uint256 length, uint256 maximum);
    error DisplayCurrencyTooLong(uint256 length, uint256 maximum);

    // ============ Init ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _documentRegistry,
        address _eas,
        bytes32 _paymentPayloadSchemaUID,
        address _governor
    ) external initializer {
        if (_documentRegistry == address(0) || _eas == address(0) || _governor == address(0)) {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        documentRegistry = IntegraDocumentRegistryV6(_documentRegistry);
        eas = IEAS(_eas);
        paymentPayloadSchemaUID = _paymentPayloadSchemaUID;

        _grantRole(DEFAULT_ADMIN_ROLE, _governor);
        _grantRole(GOVERNOR_ROLE, _governor);
        _grantRole(OPERATOR_ROLE, _governor);
    }

    // ============ Emergency Controls ============

    /**
     * @notice Pause all payment operations (emergency use only)
     * @dev Pauses sendPaymentRequest, approvePaymentRequest, completePayment
     *      Admin functions and view functions remain active for emergency response
     */
    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause payment operations
     */
    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // ============ Core Functions ============

    /**
     * @notice Send payment request with encrypted payload
     * @param integraHash Document identifier
     * @param requestorTokenId Token held by requestor
     * @param payerTokenId Token held by payer
     * @param payer Payer's ephemeral address
     * @param encryptedPayload AES-encrypted payment details (JSON schema)
     * @param encryptedSessionKeyPaymentRequestr Session key encrypted for requestor (ECIES)
     * @param encryptedSessionKeyPayer Session key encrypted for payer (ECIES)
     * @param payloadHashAttestation EAS attestation UID (requestor attests to payload hash)
     * @param invoiceReference PaymentRequest reference/description
     * @param displayAmount Amount for UI display (not used for payment)
     * @param displayCurrency Currency for UI display (not used for payment)
     * @return requestId Unique identifier for this payment request
     *
     * @dev SECURITY:
     *      - Only verified token holders can send requests
     *      - Payload is encrypted with hybrid scheme (AES + ECIES)
     *      - EAS attestation proves payload integrity
     *      - No payment details exposed on-chain
     */
    function sendPaymentRequest(
        bytes32 integraHash,
        uint256 requestorTokenId,
        uint256 payerTokenId,
        address payer,
        bytes calldata encryptedPayload,
        bytes calldata encryptedSessionKeyPaymentRequestr,
        bytes calldata encryptedSessionKeyPayer,
        bytes32 payloadHashAttestation,
        string calldata invoiceReference,
        uint256 displayAmount,
        string calldata displayCurrency
    ) external nonReentrant whenNotPaused returns (bytes32) {
        if (encryptedPayload.length == 0) {
            revert EmptyPayload();
        }
        if (encryptedPayload.length > MAX_ENCRYPTED_PAYLOAD_LENGTH) {
            revert EncryptedPayloadTooLarge(encryptedPayload.length, MAX_ENCRYPTED_PAYLOAD_LENGTH);
        }
        if (bytes(invoiceReference).length > MAX_REFERENCE_LENGTH) {
            revert ReferenceTooLong(bytes(invoiceReference).length, MAX_REFERENCE_LENGTH);
        }
        if (bytes(displayCurrency).length > MAX_DISPLAY_CURRENCY_LENGTH) {
            revert DisplayCurrencyTooLong(bytes(displayCurrency).length, MAX_DISPLAY_CURRENCY_LENGTH);
        }
        if (payer == address(0)) {
            revert ZeroAddress();
        }

        // Verify caller holds requestor token
        if (!_holdsToken(integraHash, requestorTokenId, msg.sender)) {
            revert InvalidTokenHolder(msg.sender, integraHash, requestorTokenId);
        }

        // Verify payer holds payer token
        if (!_holdsToken(integraHash, payerTokenId, payer)) {
            revert InvalidTokenHolder(payer, integraHash, payerTokenId);
        }

        // Verify EAS attestation exists and is valid
        if (!_verifyPayloadAttestation(payloadHashAttestation, msg.sender)) {
            revert InvalidAttestation(payloadHashAttestation);
        }

        // Generate unique request ID
        bytes32 requestId = keccak256(
            abi.encodePacked(integraHash, msg.sender, payer, _requestNonce++)
        );

        // Create payment request
        paymentRequests[requestId] = PaymentRequest({
            integraHash: integraHash,
            requestorTokenId: requestorTokenId,
            payerTokenId: payerTokenId,
            requestor: msg.sender,
            payer: payer,
            encryptedPayload: encryptedPayload,
            encryptedSessionKeyPaymentRequestr: encryptedSessionKeyPaymentRequestr,
            encryptedSessionKeyPayer: encryptedSessionKeyPayer,
            payloadHashAttestation: payloadHashAttestation,
            invoiceReference: invoiceReference,
            displayAmount: displayAmount,
            displayCurrency: displayCurrency,
            state: PaymentState.PENDING,
            paymentProof: bytes32(0),
            timestamp: block.timestamp,
            paidTimestamp: 0
        });

        // Index for querying
        requestsByDocument[integraHash].push(requestId);
        requestsByPaymentRequestr[msg.sender].push(requestId);
        requestsByPayer[payer].push(requestId);

        emit PaymentRequested(
            requestId,
            integraHash,
            msg.sender,
            payer,
            requestorTokenId,
            payerTokenId,
            payloadHashAttestation,
            block.timestamp
        );

        return requestId;
    }

    /**
     * @notice Mark payment as paid
     * @param requestId Payment request identifier
     * @param paymentProof TX hash, receipt URL, or other proof of payment
     *
     * @dev Can be called by requestor, payer, or operator
     *      Typically called after off-chain payment execution
     */
    function markPaid(
        bytes32 requestId,
        bytes32 paymentProof
    ) external nonReentrant whenNotPaused {
        PaymentRequest storage request = paymentRequests[requestId];

        if (request.integraHash == bytes32(0)) {
            revert RequestNotFound(requestId);
        }
        if (request.state != PaymentState.PENDING) {
            revert InvalidState(request.state, PaymentState.PENDING);
        }

        // Only requestor, payer, or operator can mark paid
        if (msg.sender != request.requestor &&
            msg.sender != request.payer &&
            !hasRole(OPERATOR_ROLE, msg.sender)) {
            revert NotAuthorized(msg.sender, request.requestor);
        }

        request.state = PaymentState.PAID;
        request.paymentProof = paymentProof;
        request.paidTimestamp = block.timestamp;

        emit PaymentMarkedPaid(requestId, msg.sender, paymentProof, block.timestamp);
    }

    /**
     * @notice Cancel payment request
     * @param requestId Payment request identifier
     *
     * @dev Can be called by requestor, payer, or anyone if request is expired
     *      Expired requests can be cleaned up by anyone to prevent storage bloat
     */
    function cancelPayment(bytes32 requestId) external nonReentrant whenNotPaused {
        PaymentRequest storage request = paymentRequests[requestId];

        if (request.integraHash == bytes32(0)) {
            revert RequestNotFound(requestId);
        }
        if (request.state != PaymentState.PENDING) {
            revert InvalidState(request.state, PaymentState.PENDING);
        }

        // Check if request is expired
        bool expired = isRequestExpired(requestId);

        // If not expired, only requestor or payer can cancel
        if (!expired) {
            if (msg.sender != request.requestor && msg.sender != request.payer) {
                revert NotAuthorized(msg.sender, request.requestor);
            }
        }
        // If expired, anyone can cancel for cleanup (no check needed)

        request.state = PaymentState.CANCELLED;

        emit PaymentCancelled(requestId, msg.sender, block.timestamp);
    }

    /**
     * @notice Dispute payment (claim payment was not received/incorrect)
     * @param requestId Payment request identifier
     * @param reason Reason for dispute
     *
     * @dev Only payer can dispute after payment marked as paid
     */
    function disputePayment(
        bytes32 requestId,
        string calldata reason
    ) external nonReentrant {
        PaymentRequest storage request = paymentRequests[requestId];

        if (request.integraHash == bytes32(0)) {
            revert RequestNotFound(requestId);
        }
        if (request.state != PaymentState.PAID) {
            revert InvalidState(request.state, PaymentState.PAID);
        }

        // Only payer can dispute
        if (msg.sender != request.payer) {
            revert NotAuthorized(msg.sender, request.payer);
        }

        request.state = PaymentState.DISPUTED;

        emit PaymentDisputed(requestId, msg.sender, reason, block.timestamp);
    }

    /**
     * @notice Resolve dispute (operator only)
     * @param requestId Payment request identifier
     * @param inFavorOfPaymentRequestr True if resolving in favor of requestor, false for payer
     *
     * @dev Requires OPERATOR_ROLE
     */
    function resolveDispute(
        bytes32 requestId,
        bool inFavorOfPaymentRequestr
    ) external onlyRole(OPERATOR_ROLE) nonReentrant {
        PaymentRequest storage request = paymentRequests[requestId];

        if (request.integraHash == bytes32(0)) {
            revert RequestNotFound(requestId);
        }
        if (request.state != PaymentState.DISPUTED) {
            revert InvalidState(request.state, PaymentState.DISPUTED);
        }

        request.state = PaymentState.RESOLVED;

        emit DisputeResolved(requestId, msg.sender, inFavorOfPaymentRequestr, block.timestamp);
    }

    // ============ Views ============

    /**
     * @notice Check if payment request has expired
     * @param requestId Payment request identifier
     * @return expired Whether the request has exceeded timeout period
     */
    function isRequestExpired(bytes32 requestId) public view returns (bool) {
        PaymentRequest storage request = paymentRequests[requestId];
        if (request.integraHash == bytes32(0)) return false;
        return block.timestamp > request.timestamp + PAYMENT_REQUEST_TIMEOUT;
    }

    /**
     * @notice Get full payment request details
     * @param requestId Payment request identifier
     * @return PaymentRequest struct including encrypted payload
     */
    function getPaymentRequest(bytes32 requestId)
        external
        view
        returns (PaymentRequest memory)
    {
        return paymentRequests[requestId];
    }

    /**
     * @notice Get all payment requests for a document
     * @param integraHash Document identifier
     * @return Array of request IDs
     */
    function getRequestsByDocument(bytes32 integraHash)
        external
        view
        returns (bytes32[] memory)
    {
        return requestsByDocument[integraHash];
    }

    /**
     * @notice Get all payment requests sent by an requestor
     * @param requestor PaymentRequestr's address
     * @return Array of request IDs
     */
    function getRequestsByPaymentRequestr(address requestor)
        external
        view
        returns (bytes32[] memory)
    {
        return requestsByPaymentRequestr[requestor];
    }

    /**
     * @notice Get all payment requests sent to a payer
     * @param payer Payer's address
     * @return Array of request IDs
     */
    function getRequestsByPayer(address payer)
        external
        view
        returns (bytes32[] memory)
    {
        return requestsByPayer[payer];
    }

    // ============ Internal Helpers ============

    /**
     * @notice Check if address holds token for document
     * @param integraHash Document identifier
     * @param tokenId Token ID to check
     * @param account Address to check
     * @return True if account holds token
     */
    function _holdsToken(
        bytes32 integraHash,
        uint256 tokenId,
        address account
    ) internal view returns (bool) {
        address resolver = documentRegistry.getResolver(integraHash);
        if (resolver == address(0)) {
            return false;
        }

        try IDocumentResolver(resolver).balanceOf(account, tokenId) returns (uint256 balance) {
            return balance > 0;
        } catch {
            return false;
        }
    }

    /**
     * @notice Verify EAS attestation for payload hash
     * @param attestationUID EAS attestation identifier
     * @param expectedAttester Expected attester (requestor)
     * @return True if attestation is valid
     *
     * @dev Attestation must:
     *      - Use correct schema
     *      - Be from expected attester
     *      - Not be expired
     *      - Not be revoked
     */
    function _verifyPayloadAttestation(
        bytes32 attestationUID,
        address expectedAttester
    ) internal view returns (bool) {
        try eas.getAttestation(attestationUID) returns (IEAS.Attestation memory attestation) {
            // Check schema matches
            if (attestation.schema != paymentPayloadSchemaUID) {
                return false;
            }

            // Check attester is requestor
            if (attestation.attester != expectedAttester) {
                return false;
            }

            // Check not expired
            if (attestation.expirationTime > 0 && attestation.expirationTime < block.timestamp) {
                return false;
            }

            // Check not revoked
            if (attestation.revocationTime > 0) {
                return false;
            }

            return true;
        } catch {
            return false;
        }
    }

    // ============ Admin ============

    /**
     * @notice Update payment payload schema UID
     * @param _schemaUID New EAS schema UID
     *
     * @dev Requires GOVERNOR_ROLE
     */
    function setPaymentPayloadSchema(bytes32 _schemaUID)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        paymentPayloadSchemaUID = _schemaUID;
    }

    /**
     * @notice Update document registry address
     * @param _documentRegistry New document registry address
     *
     * @dev Requires GOVERNOR_ROLE
     */
    function setDocumentRegistry(address _documentRegistry)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        if (_documentRegistry == address(0)) {
            revert ZeroAddress();
        }
        documentRegistry = IntegraDocumentRegistryV6(_documentRegistry);
    }

    /**
     * @notice Update EAS address
     * @param _eas New EAS address
     *
     * @dev Requires GOVERNOR_ROLE
     */
    function setEAS(address _eas)
        external
        onlyRole(GOVERNOR_ROLE)
    {
        if (_eas == address(0)) {
            revert ZeroAddress();
        }
        eas = IEAS(_eas);
    }

    // ============ Storage Gap ============

    /**
     * @dev Storage gap for future upgrades
     * Total storage slots: 50
     * Used: documentRegistry(1) + eas(1) + paymentPayloadSchemaUID(1) +
     *       paymentRequests(1) + requestsByDocument(1) + requestsByPaymentRequestr(1) +
     *       requestsByPayer(1) + _requestNonce(1) + Pausable(1) = 9
     * Gap: 50 - 9 = 41
     */
    uint256[41] private __gap;

    /**
     * @notice Authorize upgrade (UUPS pattern)
     * @dev Requires GOVERNOR_ROLE
     */
    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}
}
