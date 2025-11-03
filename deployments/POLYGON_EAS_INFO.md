# Polygon EAS Configuration

**EAS Version:** 1.3.0
**Network:** Polygon Mainnet (Chain ID: 137)

## Contract Addresses

| Contract | Address | Purpose |
|----------|---------|---------|
| **EAS** | `0x5E634ef5355f45A855d02D66eCD687b1502AF790` | Core attestation service |
| **SchemaRegistry** | `0x7876EEF51A891E737AF8ba5A5E0f0Fd29073D5a7` | Register attestation schemas |
| **EIP712Proxy** | `0x4be71865917C7907ccA531270181D9B7dD4f2733` | EIP-712 signature support |
| **Indexer** | `0x12d0f50Eb2d67b14293bdDA2C248358f3dfE5308` | Attestation indexing |

## Resources

- **Documentation:** https://docs.attest.org/
- **Explorer:** https://polygon.easscan.org/
- **ABI Files:** Available at https://github.com/ethereum-attestation-service/eas-contracts

## Integration

These addresses are required for:
- Layer 3 Resolvers (OwnershipResolverV6, SharesResolverV6, MultiPartyResolverV6)
- Layer 4 Communication (IntegraSignalV6)
- AttestationAccessControlV6 base contract

## Schemas Needed

Before deploying resolvers, register these schemas on SchemaRegistry:

1. **Access Capability Schema** (for resolver access control):
   ```
   bytes32 documentHash, uint256 tokenId, uint256 capabilities, 
   string verifiedIdentity, string verificationMethod, uint256 verificationDate,
   string contractRole, string legalEntityType, string notes
   ```

2. **Credential Schema** (for trust graph):
   ```
   bytes32 credentialHash
   ```

3. **Payment Payload Schema** (for IntegraSignalV6):
   ```
   bytes32 payloadHash
   ```

Register schemas at: https://polygon.easscan.org/schema/create
