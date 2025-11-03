// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../layer6/IntegraVerifierRegistry.sol";

/**
 * @title IntegraMessage
 * @notice Workflow event messaging system
 *
 * V6 ARCHITECTURE (Based on V5):
 * - Poseidon hash for all ID generation (ZK-friendly, no split hash needed)
 * - ZK proof required for processHash (anti-spam protection)
 * - Event-sourced design (no storage, messages indexed off-chain)
 * - No correlation checking (done by off-chain software)
 * - No trust graph integration (removed privacy leak)
 *
 * PURPOSE:
 * Allows document participants to register messages for workflow events.
 * Messages are correlated to integraHash and processHash.
 * ZK proofs prevent spam by requiring knowledge of the IDs.
 *
 * IMPORTANT:
 * - Contract does NOT verify that integraHash/processHash are related
 * - Contract does NOT check if documents exist
 * - Correlation is handled by off-chain indexers/software
 * - If no correlation exists, message is stored but useless (no one sees it)
 */
contract IntegraMessage is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ============ State ============

    IntegraVerifierRegistry public verifierRegistry;

    // ============ Constants ============

    uint256 public constant MAX_EVENT_REF_LENGTH = 100;
    uint256 public constant MAX_MESSAGE_LENGTH = 1000;

    // ============ Events ============

    event MessageRegistered(
        bytes32 indexed integraHash,
        bytes32 indexed processHash,
        uint256 indexed tokenId,
        string eventRef,
        string message,
        uint256 timestamp,
        address registrant
    );

    // ============ Errors ============

    error MessageCannotBeEmpty();
    error InvalidProof();
    error VerifierNotFound();
    error InvalidIntegraHash();
    error InvalidProcessHash();
    error EventRefRequired();
    error EventRefTooLong(uint256 length, uint256 maximum);
    error MessageTooLong(uint256 length, uint256 maximum);
    error ZeroAddress();

    // ============ Init ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _verifierRegistry,
        address _governor
    ) external initializer {
        if (_verifierRegistry == address(0) || _governor == address(0)) {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        verifierRegistry = IntegraVerifierRegistry(_verifierRegistry);

        _grantRole(DEFAULT_ADMIN_ROLE, _governor);
        _grantRole(GOVERNOR_ROLE, _governor);
        _grantRole(OPERATOR_ROLE, _governor);
    }

    // ============ Core Functions ============

    /**
     * @notice Register a message for a workflow event with ZK proof
     * @param integraHash Document identifier
     * @param tokenId Token holder identifier (optional, can be 0)
     * @param processHash Workflow/process identifier (requires zkProof)
     * @param proofA ZK proof component A
     * @param proofB ZK proof component B
     * @param proofC ZK proof component C
     * @param eventRef Event identifier/reference
     * @param message Message content
     *
     * SECURITY: Requires proof of knowledge for processHash to prevent spam
     *
     * ARCHITECTURE NOTES:
     * - ZK proof proves you know the processHash (anti-spam)
     * - Contract does NOT verify integraHash/processHash correlation
     * - Contract does NOT check if documents exist
     * - Correlation checking happens off-chain in software
     * - Messages with invalid correlations are stored but ignored
     */
    function registerMessage(
        bytes32 integraHash,
        uint256 tokenId,
        bytes32 processHash,
        uint256[2] calldata proofA,
        uint256[2][2] calldata proofB,
        uint256[2] calldata proofC,
        string calldata eventRef,
        string calldata message
    ) external nonReentrant whenNotPaused {
        // ============================================
        // Input validation
        // ============================================
        if (integraHash == bytes32(0)) revert InvalidIntegraHash();
        if (processHash == bytes32(0)) revert InvalidProcessHash();
        if (bytes(eventRef).length == 0) revert EventRefRequired();
        if (bytes(eventRef).length > MAX_EVENT_REF_LENGTH) {
            revert EventRefTooLong(bytes(eventRef).length, MAX_EVENT_REF_LENGTH);
        }
        if (bytes(message).length == 0) revert MessageCannotBeEmpty();
        if (bytes(message).length > MAX_MESSAGE_LENGTH) {
            revert MessageTooLong(bytes(message).length, MAX_MESSAGE_LENGTH);
        }

        // ============================================
        // SECURITY: ZK PROOF VERIFICATION (ANTI-SPAM)
        // Proves caller knows the processHash
        // V6 ARCHITECTURE: Poseidon hash passed directly as uint256 (native field element)
        // ============================================
        bytes32 verifierId = keccak256(abi.encodePacked("BasicAccessV1Poseidon", "v1"));
        address verifier = verifierRegistry.getVerifier(verifierId);
        if (verifier == address(0)) {
            revert VerifierNotFound();
        }

        (bool success, bytes memory result) = verifier.staticcall(
            abi.encodeWithSignature(
                "verifyProof(uint256[2],uint256[2][2],uint256[2],uint256)",
                proofA,
                proofB,
                proofC,
                uint256(processHash)
            )
        );

        if (!success || !abi.decode(result, (bool))) {
            revert InvalidProof();
        }

        // ============================================
        // Emit event - messages are event-sourced
        // No storage needed, all data in events
        // Off-chain software indexes and correlates
        // ============================================
        emit MessageRegistered(
            integraHash,
            processHash,
            tokenId,
            eventRef,
            message,
            block.timestamp,
            msg.sender
        );
    }

    // ============ Emergency Controls ============

    /**
     * @dev Pause contract operations
     */
    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause contract operations
     */
    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // ============ Admin ============

    function setVerifierRegistry(address _verifierRegistry) external onlyRole(GOVERNOR_ROLE) {
        if (_verifierRegistry == address(0)) {
            revert ZeroAddress();
        }
        verifierRegistry = IntegraVerifierRegistry(_verifierRegistry);
    }

    // ============ Storage Gap ============

    /**
     * @dev Storage gap for future upgrades
     * Gap calculation: 50 - 1 state variable = 49 slots
     * State variable: verifierRegistry (1)
     */
    uint256[49] private __gap;

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}
}
