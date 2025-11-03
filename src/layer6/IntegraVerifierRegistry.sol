// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title IntegraVerifierRegistry
 * @notice Registry for ZK circuit verifiers
 *
 * Manages multiple ZK verifiers for different proof types.
 *
 * NEW IN V3: Complete implementation (Issue #2)
 */
contract IntegraVerifierRegistry is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // ============ Constants ============

    uint256 public constant MAX_VERIFIERS_PER_TYPE = 100;
    uint256 public constant MAX_CIRCUIT_TYPE_LENGTH = 100;
    uint256 public constant MAX_VERSION_LENGTH = 50;

    // ============ Types ============

    struct VerifierInfo {
        address verifier;
        string circuitType;
        string version;
        bool active;
        uint256 registeredAt;
    }

    // ============ State ============

    mapping(bytes32 verifierId => VerifierInfo info) public verifiers;
    mapping(string circuitType => bytes32[] verifierIds) public verifiersByType;
    bytes32[] public allVerifiers;

    // ============ Events ============

    event VerifierRegistered(
        bytes32 indexed verifierId,
        address indexed verifier,
        string circuitType,
        string version,
        uint256 timestamp
    );

    event VerifierDeactivated(bytes32 indexed verifierId, uint256 timestamp);
    event VerifierActivated(bytes32 indexed verifierId, uint256 timestamp);

    // ============ Errors ============

    error VerifierAlreadyRegistered(bytes32 verifierId);
    error VerifierNotFound(bytes32 verifierId);
    error ZeroAddress();
    error CircuitTypeTooLong(uint256 length, uint256 maximum);
    error VersionTooLong(uint256 length, uint256 maximum);
    error TooManyVerifiersForType(string circuitType, uint256 count, uint256 maximum);

    // ============ Init ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _governor) external initializer {
        if (_governor == address(0)) {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _governor);
        _grantRole(GOVERNOR_ROLE, _governor);
        _grantRole(OPERATOR_ROLE, _governor);
        _grantRole(EXECUTOR_ROLE, _governor);
    }

    // ============ Emergency Controls ============

    /**
     * @notice Pause all verifier operations (emergency use only)
     * @dev Pauses registerVerifier, deactivateVerifier, activateVerifier
     *      Admin functions and view functions remain active for emergency response
     */
    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause verifier operations
     */
    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // ============ Core Functions ============

    function registerVerifier(
        address verifier,
        string calldata circuitType,
        string calldata version
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused returns (bytes32) {
        if (verifier == address(0)) {
            revert ZeroAddress();
        }

        // Validate input lengths
        if (bytes(circuitType).length > MAX_CIRCUIT_TYPE_LENGTH) {
            revert CircuitTypeTooLong(bytes(circuitType).length, MAX_CIRCUIT_TYPE_LENGTH);
        }
        if (bytes(version).length > MAX_VERSION_LENGTH) {
            revert VersionTooLong(bytes(version).length, MAX_VERSION_LENGTH);
        }

        bytes32 verifierId = keccak256(abi.encodePacked(circuitType, version));

        if (verifiers[verifierId].verifier != address(0)) {
            revert VerifierAlreadyRegistered(verifierId);
        }

        // Check verifier count limit for this type
        if (verifiersByType[circuitType].length >= MAX_VERIFIERS_PER_TYPE) {
            revert TooManyVerifiersForType(circuitType, verifiersByType[circuitType].length, MAX_VERIFIERS_PER_TYPE);
        }

        verifiers[verifierId] = VerifierInfo({
            verifier: verifier,
            circuitType: circuitType,
            version: version,
            active: true,
            registeredAt: block.timestamp
        });

        verifiersByType[circuitType].push(verifierId);
        allVerifiers.push(verifierId);

        emit VerifierRegistered(verifierId, verifier, circuitType, version, block.timestamp);

        return verifierId;
    }

    function deactivateVerifier(bytes32 verifierId) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (verifiers[verifierId].verifier == address(0)) {
            revert VerifierNotFound(verifierId);
        }

        verifiers[verifierId].active = false;

        emit VerifierDeactivated(verifierId, block.timestamp);
    }

    function activateVerifier(bytes32 verifierId) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (verifiers[verifierId].verifier == address(0)) {
            revert VerifierNotFound(verifierId);
        }

        verifiers[verifierId].active = true;

        emit VerifierActivated(verifierId, block.timestamp);
    }

    // ============ Views ============

    function getVerifier(bytes32 verifierId) external view returns (address) {
        return verifiers[verifierId].verifier;
    }

    function getVerifierInfo(bytes32 verifierId) external view returns (VerifierInfo memory) {
        return verifiers[verifierId];
    }

    function getVerifiersByType(string calldata circuitType) external view returns (bytes32[] memory) {
        return verifiersByType[circuitType];
    }

    function getAllVerifiers() external view returns (bytes32[] memory) {
        return allVerifiers;
    }

    function isVerifierActive(bytes32 verifierId) external view returns (bool) {
        return verifiers[verifierId].active;
    }

    // ============ Storage Gap ============

    /**
     * @dev Storage gap for future upgrades
     * Gap calculation: 50 - 4 state variables = 46 slots
     * State variables: verifiers (1), verifiersByType (1), allVerifiers (1), Pausable (1)
     */
    uint256[46] private __gap;

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}
}
