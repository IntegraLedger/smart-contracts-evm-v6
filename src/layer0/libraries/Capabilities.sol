// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Capabilities
 * @notice Library for capability-based access control
 * @dev Provides constants and helper functions for capability bitmask operations
 *
 * Capability flags are combined using bitwise OR to create permission sets.
 * This allows granular, composable permissions without complex role hierarchies.
 *
 * Example:
 *   uint256 holderPermissions = CLAIM_TOKEN | REQUEST_PAYMENT;
 *   // Result: 0x05 (binary: 0101)
 *   // Grants both CLAIM_TOKEN and REQUEST_PAYMENT capabilities
 */
library Capabilities {
    // ============ Capability Flags ============

    /**
     * @notice Can claim reserved tokens
     * @dev Required for: claimToken(), requestClaim()
     */
    uint256 internal constant CLAIM_TOKEN = 0x01;

    /**
     * @notice Can transfer token ownership
     * @dev Required for: transferToken(), safeTransferFrom()
     */
    uint256 internal constant TRANSFER_TOKEN = 0x02;

    /**
     * @notice Can request payments
     * @dev Required for: requestPayment(), submitPaymentRequest()
     */
    uint256 internal constant REQUEST_PAYMENT = 0x04;

    /**
     * @notice Can approve payments
     * @dev Required for: approvePayment(), rejectPayment()
     */
    uint256 internal constant APPROVE_PAYMENT = 0x08;

    /**
     * @notice Can update document metadata
     * @dev Required for: updateMetadata(), setDocumentURI()
     */
    uint256 internal constant UPDATE_METADATA = 0x10;

    /**
     * @notice Can delegate rights to others
     * @dev Required for: delegateRights(), grantCapability()
     */
    uint256 internal constant DELEGATE_RIGHTS = 0x20;

    /**
     * @notice Can revoke access from others
     * @dev Required for: revokeAccess(), revokeCapability()
     */
    uint256 internal constant REVOKE_ACCESS = 0x40;

    /**
     * @notice Full admin rights (implies all other capabilities)
     * @dev Admin can perform any operation without additional checks
     */
    uint256 internal constant ADMIN = 0x80;

    // ============ Helper Functions ============

    /**
     * @notice Check if capability set includes required capability
     * @param granted Granted capabilities (bitmask)
     * @param required Required capability (bitmask)
     * @return Whether required capability is granted
     *
     * @dev Examples:
     *   granted = 0x05 (CLAIM_TOKEN | REQUEST_PAYMENT)
     *   required = 0x01 (CLAIM_TOKEN)
     *   → returns true
     *
     *   granted = 0x05 (CLAIM_TOKEN | REQUEST_PAYMENT)
     *   required = 0x08 (APPROVE_PAYMENT)
     *   → returns false
     *
     *   granted = 0x80 (ADMIN)
     *   required = any
     *   → returns true
     */
    function hasCapability(uint256 granted, uint256 required) internal pure returns (bool) {
        // Admin has all capabilities
        if ((granted & ADMIN) == ADMIN) {
            return true;
        }

        // Check if all required bits are set in granted
        return (granted & required) == required;
    }

    /**
     * @notice Add capability to existing set
     * @param current Current capabilities
     * @param toAdd Capability to add
     * @return Updated capabilities
     *
     * @dev Example:
     *   current = 0x01 (CLAIM_TOKEN)
     *   toAdd = 0x04 (REQUEST_PAYMENT)
     *   → returns 0x05 (CLAIM_TOKEN | REQUEST_PAYMENT)
     */
    function addCapability(uint256 current, uint256 toAdd) internal pure returns (uint256) {
        return current | toAdd;
    }

    /**
     * @notice Remove capability from existing set
     * @param current Current capabilities
     * @param toRemove Capability to remove
     * @return Updated capabilities
     *
     * @dev Example:
     *   current = 0x05 (CLAIM_TOKEN | REQUEST_PAYMENT)
     *   toRemove = 0x01 (CLAIM_TOKEN)
     *   → returns 0x04 (REQUEST_PAYMENT)
     */
    function removeCapability(uint256 current, uint256 toRemove) internal pure returns (uint256) {
        return current & ~toRemove;
    }

    /**
     * @notice Check if capability set has any capabilities
     * @param capabilities Capability bitmask
     * @return Whether any capabilities are set
     */
    function hasAnyCapability(uint256 capabilities) internal pure returns (bool) {
        return capabilities != 0;
    }

    /**
     * @notice Get human-readable capability names
     * @param capabilities Capability bitmask
     * @return Array of capability flags that are set
     *
     * @dev Used for debugging and UI display
     */
    function getCapabilityFlags(uint256 capabilities) internal pure returns (uint256[] memory) {
        // Count set flags
        uint256 count = 0;
        for (uint256 i = 0; i < 8; i++) {
            if ((capabilities & (1 << i)) != 0) {
                count++;
            }
        }

        // Build array of set flags
        uint256[] memory flags = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < 8; i++) {
            uint256 flag = 1 << i;
            if ((capabilities & flag) != 0) {
                flags[index] = flag;
                index++;
            }
        }

        return flags;
    }

    /**
     * @notice Check if capabilities represent admin
     * @param capabilities Capability bitmask
     * @return Whether ADMIN flag is set
     */
    function isAdmin(uint256 capabilities) internal pure returns (bool) {
        return (capabilities & ADMIN) == ADMIN;
    }
}
