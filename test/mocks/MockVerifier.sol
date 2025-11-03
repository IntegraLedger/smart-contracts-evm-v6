// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MockVerifier
 * @notice Mock ZK proof verifier for testing
 */
contract MockVerifier {
    bool public shouldAcceptProof = true;

    function setShouldAcceptProof(bool _shouldAccept) external {
        shouldAcceptProof = _shouldAccept;
    }

    function verifyProof(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256
    ) external view returns (bool) {
        return shouldAcceptProof;
    }
}
