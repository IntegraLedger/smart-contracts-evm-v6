// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPaymentHelper
 * @notice Standard interface for Layer 5 payment execution helpers
 *
 * All payment helpers should implement this interface to ensure consistency
 * and interoperability with IntegraSignal (Layer 4).
 *
 * DESIGN PRINCIPLES:
 * 1. Helpers are stateless executors (no storage of payment data)
 * 2. Helpers read from IntegraSignal (source of truth)
 * 3. Helpers automatically mark payments as paid
 * 4. Helpers accept user-decrypted data (don't decrypt themselves)
 */
interface IPaymentHelper {
    // ============ Events ============

    /**
     * @notice Emitted when a payment is executed via helper
     * @param requestId IntegraSignal payment request ID
     * @param executor Address that called the helper
     * @param success Whether execution succeeded
     * @param txHash Transaction hash or proof of payment
     */
    event PaymentExecuted(
        bytes32 indexed requestId,
        address indexed executor,
        bool success,
        bytes32 txHash
    );

    /**
     * @notice Emitted when multiple payments are executed in batch
     * @param requestIds Array of IntegraSignal payment request IDs
     * @param executor Address that called the helper
     * @param successCount Number of successful payments
     * @param totalAmount Total amount paid across all requests
     */
    event BatchPaymentExecuted(
        bytes32[] requestIds,
        address indexed executor,
        uint256 successCount,
        uint256 totalAmount
    );

    // ============ Core Functions ============

    /**
     * @notice Execute payment from IntegraSignal request
     *
     * @param requestId IntegraSignal payment request ID
     * @param additionalData Helper-specific configuration data
     *
     * @return success Whether payment executed successfully
     *
     * @dev Process:
     *      1. Fetch payment request from IntegraSignal
     *      2. Validate request (pending, authorized, etc.)
     *      3. Execute payment using helper's specialized logic
     *      4. Automatically call integraSignal.markPaid()
     *      5. Emit PaymentExecuted event
     *
     * @dev Security:
     *      - Must verify msg.sender is authorized (payer or approved)
     *      - Must validate request state is PENDING
     *      - Should use nonReentrant modifier
     *      - Should require appropriate token approvals
     */
    function executeFromSignal(
        bytes32 requestId,
        bytes calldata additionalData
    ) external returns (bool success);

    /**
     * @notice Batch execute multiple payment requests atomically
     *
     * @param requestIds Array of IntegraSignal request IDs
     * @param additionalData Helper-specific configuration data
     *
     * @return success Whether all payments executed successfully
     *
     * @dev Process:
     *      1. Fetch all payment requests from IntegraSignal
     *      2. Validate all requests (same checks as executeFromSignal)
     *      3. Execute batch payment logic (e.g., one transaction for all)
     *      4. Mark all as paid via integraSignal.markPaid()
     *      5. Emit BatchPaymentExecuted event
     *
     * @dev Atomicity:
     *      - Either all payments succeed or all revert
     *      - Use careful gas estimation for large batches
     *      - Consider gas limits on batch size
     */
    function executeBatchFromSignal(
        bytes32[] calldata requestIds,
        bytes calldata additionalData
    ) external returns (bool success);

    // ============ View Functions ============

    /**
     * @notice Check if helper supports a specific payment method
     *
     * @param method Payment method from IntegraSignal payload
     *               (e.g., "crypto", "stream", "crosschain")
     *
     * @return supported Whether this helper supports the method
     *
     * @dev Examples:
     *      - ProRataPaymentHelper: supports "crypto"
     *      - SuperfluidStreamingHelper: supports "stream"
     *      - CCIPCrossChainHelper: supports "crosschain"
     */
    function supportsMethod(string calldata method) external view returns (bool supported);

    /**
     * @notice Estimate gas cost for executing payment
     *
     * @param requestId IntegraSignal payment request ID
     *
     * @return gasEstimate Estimated gas units required
     *
     * @dev Use cases:
     *      - Users can estimate transaction cost before executing
     *      - Front-end can display estimated fees
     *      - Useful for batch size optimization
     */
    function estimateGas(bytes32 requestId) external view returns (uint256 gasEstimate);

    /**
     * @notice Estimate gas cost for batch execution
     *
     * @param requestIds Array of IntegraSignal request IDs
     *
     * @return gasEstimate Estimated gas units required
     */
    function estimateBatchGas(bytes32[] calldata requestIds)
        external
        view
        returns (uint256 gasEstimate);

    /**
     * @notice Get helper-specific configuration or metadata
     *
     * @return name Helper name (e.g., "ProRataPaymentHelper")
     * @return version Helper version (e.g., "1.0.0")
     * @return description Human-readable description
     *
     * @dev Useful for:
     *      - UI discovery of available helpers
     *      - Version compatibility checks
     *      - Documentation generation
     */
    function getHelperInfo()
        external
        view
        returns (
            string memory name,
            string memory version,
            string memory description
        );
}
