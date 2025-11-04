// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/layer0/interfaces/IEAS.sol";

/**
 * @title MockEAS
 * @notice Simplified mock EAS for testing - implements only essential functions
 */
contract MockEAS {
    struct StoredAttestation {
        bytes32 uid;
        bytes32 schema;
        uint64 time;
        uint64 expirationTime;
        uint64 revocationTime;
        bytes32 refUID;
        address recipient;
        address attester;
        bool revocable;
        bytes data;
    }

    mapping(bytes32 => StoredAttestation) public attestations;
    uint256 private _nextUID = 1;

    function attest(IEAS.AttestationRequest calldata request)
        external
        payable
        returns (bytes32)
    {
        bytes32 uid = bytes32(_nextUID++);

        attestations[uid] = StoredAttestation({
            uid: uid,
            schema: request.schema,
            time: uint64(block.timestamp),
            expirationTime: request.data.expirationTime,
            revocationTime: 0,
            refUID: request.data.refUID,
            recipient: request.data.recipient,
            attester: msg.sender,
            revocable: request.data.revocable,
            data: request.data.data
        });

        return uid;
    }

    function getAttestation(bytes32 uid)
        external
        view
        returns (IEAS.Attestation memory)
    {
        StoredAttestation storage stored = attestations[uid];

        return IEAS.Attestation({
            uid: stored.uid,
            schema: stored.schema,
            time: stored.time,
            expirationTime: stored.expirationTime,
            revocationTime: stored.revocationTime,
            refUID: stored.refUID,
            recipient: stored.recipient,
            attester: stored.attester,
            revocable: stored.revocable,
            data: stored.data
        });
    }

    function isAttestationValid(bytes32 uid) external view returns (bool) {
        StoredAttestation storage attestation = attestations[uid];

        if (attestation.time == 0) return false;
        if (attestation.revocationTime != 0) return false;
        if (attestation.expirationTime != 0 && block.timestamp > attestation.expirationTime) {
            return false;
        }

        return true;
    }

    function revoke(IEAS.RevocationRequest calldata request) external payable {
        attestations[request.data.uid].revocationTime = uint64(block.timestamp);
    }
}
