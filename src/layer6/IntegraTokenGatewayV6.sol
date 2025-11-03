// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IntegraTokenGateway
 * @notice Fee collection in Integra tokens for platform operations
 *
 * NEW IN V3: Complete implementation (Issue #2)
 */
contract IntegraTokenGatewayV6 is
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // ============ Constants ============

    uint256 public constant MAX_FEE_AMOUNT = 1000000 * 10**18; // 1M tokens max
    uint256 public constant MAX_BATCH_CHARGE_SIZE = 100;

    // ============ State ============

    IERC20 public integraToken;
    address public treasury;

    mapping(bytes4 operation => uint256 fee) public operationFees;
    mapping(address user => bool exempted) public feeExemptions;

    // ============ Events ============

    event FeeCharged(
        address indexed user,
        bytes4 indexed operation,
        uint256 amount,
        uint256 timestamp
    );

    event OperationFeeSet(bytes4 indexed operation, uint256 oldFee, uint256 newFee, uint256 timestamp);
    event FeeExemptionSet(address indexed user, bool exempted, uint256 timestamp);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury, uint256 timestamp);

    // ============ Errors ============

    error InsufficientBalance(address user, uint256 required, uint256 actual);
    error ZeroAddress();
    error FeeTooHigh(uint256 fee, uint256 maximum);

    // ============ Init ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _integraToken,
        address _treasury,
        address _governor
    ) external initializer {
        if (_integraToken == address(0) || _treasury == address(0) || _governor == address(0)) {
            revert ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        integraToken = IERC20(_integraToken);
        treasury = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, _governor);
        _grantRole(GOVERNOR_ROLE, _governor);
        _grantRole(OPERATOR_ROLE, _governor);
        _grantRole(EXECUTOR_ROLE, _governor);
    }

    // ============ Emergency Controls ============

    /**
     * @notice Pause all fee operations (emergency use only)
     */
    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause fee operations
     */
    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // ============ Core Functions ============

    function chargeFee(address user, bytes4 operation)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        if (feeExemptions[user]) {
            return true;
        }

        uint256 fee = operationFees[operation];
        if (fee == 0) {
            return true;
        }

        uint256 balance = integraToken.balanceOf(user);
        if (balance < fee) {
            revert InsufficientBalance(user, fee, balance);
        }

        integraToken.safeTransferFrom(user, treasury, fee);

        emit FeeCharged(user, operation, fee, block.timestamp);

        return true;
    }

    function getFee(bytes4 operation, address user) external view returns (uint256) {
        if (feeExemptions[user]) {
            return 0;
        }
        return operationFees[operation];
    }

    // ============ Admin ============

    function setOperationFee(bytes4 operation, uint256 newFee) external onlyRole(GOVERNOR_ROLE) {
        if (newFee > MAX_FEE_AMOUNT) {
            revert FeeTooHigh(newFee, MAX_FEE_AMOUNT);
        }
        uint256 oldFee = operationFees[operation];
        operationFees[operation] = newFee;
        emit OperationFeeSet(operation, oldFee, newFee, block.timestamp);
    }

    function setFeeExemption(address user, bool exempted) external onlyRole(GOVERNOR_ROLE) {
        feeExemptions[user] = exempted;
        emit FeeExemptionSet(user, exempted, block.timestamp);
    }

    function setTreasury(address newTreasury) external onlyRole(GOVERNOR_ROLE) {
        if (newTreasury == address(0)) {
            revert ZeroAddress();
        }
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury, block.timestamp);
    }

    // ============ Storage Gap ============

    /**
     * @dev Storage gap for future upgrades
     * Gap calculation: 50 - 4 state variables - 2 inherited (ReentrancyGuard + Pausable) = 44 slots
     * State variables: integraToken (1), treasury (1),
     *                 operationFees (1), feeExemptions (1)
     */
    uint256[44] private __gap;

    function _authorizeUpgrade(address) internal override onlyRole(GOVERNOR_ROLE) {}
}
