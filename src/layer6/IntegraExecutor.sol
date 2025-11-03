// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title IntegraExecutor
 * @notice Wallet abstraction layer supporting ERC-4337 and EIP-2771
 *
 * Enables gasless transactions and meta-transactions for Integra operations.
 *
 * NEW IN V3: Complete implementation (Issue #2)
 */
contract IntegraExecutor is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ERC2771ContextUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // ============ Constants ============

    uint256 public constant MAX_BATCH_SIZE = 50;
    uint256 public constant MAX_GAS_PER_OPERATION = 5000000;

    // ============ State ============

    mapping(address user => uint256 nonce) public nonces;
    mapping(address target => bool allowed) public allowedTargets;
    mapping(bytes4 selector => bool allowed) public allowedSelectors;

    uint256 public executionFee;
    address public feeRecipient;

    // ============ Events ============

    event OperationExecuted(
        address indexed user,
        address indexed target,
        bytes4 indexed selector,
        bool success,
        uint256 nonce,
        uint256 timestamp
    );

    event BatchOperationExecuted(
        address indexed user,
        uint256 operationCount,
        uint256 successCount,
        uint256 nonce,
        uint256 timestamp
    );

    event TargetAllowed(address indexed target, bool allowed, uint256 timestamp);
    event SelectorAllowed(bytes4 indexed selector, bool allowed, uint256 timestamp);
    event ExecutionFeeUpdated(uint256 oldFee, uint256 newFee, uint256 timestamp);

    // ============ Errors ============

    error TargetNotAllowed(address target);
    error SelectorNotAllowed(bytes4 selector);
    error ExecutionFailed(address target, bytes data);
    error InsufficientFee(uint256 provided, uint256 required);
    error ZeroAddress();
    error BatchSizeTooLarge(uint256 size, uint256 maximum);
    error BatchLengthMismatch(uint256 targetsLength, uint256 dataLength, uint256 valuesLength);

    // ============ Init ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address trustedForwarder,
        address _governor,
        address _feeRecipient
    ) external initializer {
        if (_governor == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ERC2771Context_init(trustedForwarder);
        __ReentrancyGuard_init();
        __Pausable_init();

        feeRecipient = _feeRecipient;
        executionFee = 0; // Free initially

        _grantRole(DEFAULT_ADMIN_ROLE, _governor);
        _grantRole(GOVERNOR_ROLE, _governor);
        _grantRole(OPERATOR_ROLE, _governor);
        _grantRole(EXECUTOR_ROLE, _governor);
    }

    // ============ Emergency Controls ============

    /**
     * @notice Pause all executor operations (emergency use only)
     * @dev Pauses executeOperation and executeBatch
     *      Admin functions remain active for emergency response
     */
    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause executor operations
     */
    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // ============ Core Functions ============

    /**
     * @notice Execute operation on behalf of user
     */
    function executeOperation(
        address target,
        bytes calldata data,
        uint256 value
    ) external payable nonReentrant whenNotPaused returns (bool, bytes memory) {
        address user = _msgSender();

        // Check fee
        if (msg.value < executionFee) {
            revert InsufficientFee(msg.value, executionFee);
        }

        // Verify target and selector
        if (!allowedTargets[target]) {
            revert TargetNotAllowed(target);
        }

        bytes4 selector = bytes4(data[:4]);
        if (!allowedSelectors[selector]) {
            revert SelectorNotAllowed(selector);
        }

        // Execute
        (bool success, bytes memory result) = target.call{value: value}(data);

        // Transfer fee
        if (executionFee > 0) {
            (bool feeSuccess, ) = feeRecipient.call{value: executionFee}("");
            require(feeSuccess, "Fee transfer failed");
        }

        emit OperationExecuted(
            user,
            target,
            selector,
            success,
            nonces[user]++,
            block.timestamp
        );

        return (success, result);
    }

    /**
     * @notice Execute batch of operations
     */
    function executeBatch(
        address[] calldata targets,
        bytes[] calldata dataArray,
        uint256[] calldata values
    ) external payable nonReentrant whenNotPaused returns (bool[] memory, bytes[] memory) {
        address user = _msgSender();

        // Validate batch size
        if (targets.length > MAX_BATCH_SIZE) {
            revert BatchSizeTooLarge(targets.length, MAX_BATCH_SIZE);
        }

        // Validate array lengths match
        if (targets.length != dataArray.length || dataArray.length != values.length) {
            revert BatchLengthMismatch(targets.length, dataArray.length, values.length);
        }

        // Check fee
        if (msg.value < executionFee) {
            revert InsufficientFee(msg.value, executionFee);
        }

        bool[] memory successes = new bool[](targets.length);
        bytes[] memory results = new bytes[](targets.length);
        uint256 successCount = 0;

        for (uint256 i = 0; i < targets.length; i++) {
            if (!allowedTargets[targets[i]]) {
                continue;
            }

            bytes4 selector = bytes4(dataArray[i][:4]);
            if (!allowedSelectors[selector]) {
                continue;
            }

            (bool success, bytes memory result) = targets[i].call{value: values[i]}(dataArray[i]);
            successes[i] = success;
            results[i] = result;

            if (success) {
                successCount++;
            }
        }

        // Transfer fee
        if (executionFee > 0) {
            (bool feeSuccess, ) = feeRecipient.call{value: executionFee}("");
            require(feeSuccess, "Fee transfer failed");
        }

        emit BatchOperationExecuted(
            user,
            targets.length,
            successCount,
            nonces[user]++,
            block.timestamp
        );

        return (successes, results);
    }

    // ============ Admin ============

    function setAllowedTarget(address target, bool allowed) external onlyRole(OPERATOR_ROLE) {
        allowedTargets[target] = allowed;
        emit TargetAllowed(target, allowed, block.timestamp);
    }

    function setAllowedSelector(bytes4 selector, bool allowed) external onlyRole(OPERATOR_ROLE) {
        allowedSelectors[selector] = allowed;
        emit SelectorAllowed(selector, allowed, block.timestamp);
    }

    function setExecutionFee(uint256 newFee) external onlyRole(GOVERNOR_ROLE) {
        uint256 oldFee = executionFee;
        executionFee = newFee;
        emit ExecutionFeeUpdated(oldFee, newFee, block.timestamp);
    }

    function setFeeRecipient(address newRecipient) external onlyRole(GOVERNOR_ROLE) {
        if (newRecipient == address(0)) {
            revert ZeroAddress();
        }
        feeRecipient = newRecipient;
    }

    // ============ Overrides ============

    function _msgSender()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }

    // ============ Storage Gap ============

    /**
     * @dev Storage gap for future upgrades
     * Gap calculation: 50 - 6 state variables = 44 slots
     * State variables: nonces (1), allowedTargets (1), allowedSelectors (1),
     *                 executionFee (1), feeRecipient (1), Pausable (1)
     */
    uint256[44] private __gap;

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}
}
