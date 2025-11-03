# V6 Smart Contract Workflows

This directory contains workflow definitions for V6 smart contracts.

**Total Workflows: 18**

## Workflows Created

### IntegraDocumentRegistryV6 (document-registry) - 6 workflows
1. **register-document.json** - Register document (user pays gas)
2. **register-document-for.json** - Register document for user (executor pays gas)
3. **set-resolver.json** - Set resolver for document (user)
4. **set-resolver-for.json** - Set resolver for document (executor)
5. **transfer-document-ownership.json** - Transfer ownership (user)
6. **transfer-document-ownership-for.json** - Transfer ownership (executor)

### Resolver Contracts (resolver) - 6 workflows
7. **reserve-token-anonymous-multiparty.json** - Reserve tokens (MultiPartyResolver)
8. **reserve-token-anonymous-ownership.json** - Reserve NFT (OwnershipResolver)
9. **reserve-token-anonymous-shares.json** - Reserve shares (SharesResolver)
10. **claim-token.json** - Claim reserved token with attestation (all resolvers)
11. **cancel-reservation.json** - Cancel reservation (issuer only, all resolvers)
12. **declare-primary-wallet.json** - Declare primary wallet (trust graph, all resolvers)

### IntegraMessageV6 (message) - 1 workflow
13. **register-message-v6.json** - Register message with ZK proof

### IntegraSignalV6 (signal) - 5 workflows
14. **send-payment-request-v6.json** - Send encrypted payment request
15. **mark-paid.json** - Mark payment as paid
16. **cancel-payment-v6.json** - Cancel payment request
17. **dispute-payment.json** - Dispute payment (payer only)
18. **resolve-dispute.json** - Resolve dispute (operator only)

## Key Differences from V4.5

- **contractVersion**: "v6.0" (instead of "v4.5")
- **contractType**: "document-registry" for DocumentRegistry (V4.5 used "ledger")
- **contractType**: "resolver" for MultiParty/Ownership/Shares resolvers
- **Attestation-based**: V6 uses EAS attestations instead of on-chain approvals
- **Encrypted payloads**: Payment details encrypted off-chain
- **Anonymous reservations**: Tokens reserved without knowing recipient address

## Workflow Structure

All workflows follow the standard Integra workflow pattern:

```json
{
  "id": "workflow-id",
  "name": "Workflow Name",
  "version": "2.0.0",
  "category": "blockchain",
  "workflow": {
    "steps": [
      {
        "actionParams": {
          "type": "blockchain",
          "chain": "polygon",
          "contractType": "document-registry",
          "contractVersion": "v6.0"
        }
      }
    ]
  },
  "blockchainSchema": {
    "method": "functionName",
    "contract": "ContractName",
    "contractType": "document-registry",
    "parameters": { ... }
  }
}
```

## Adding to Database

To add these workflows to the workflow_library database:

```bash
# Example for one workflow
wrangler d1 execute shared-registry-prod --remote --command "
  INSERT INTO workflow_library (workflow_id, name, version, manifest, is_active, created_at, updated_at)
  VALUES (
    'register-document',
    'Register Document (V6)',
    '2.0.0',
    '<json-escaped-manifest>',
    1,
    datetime('now'),
    datetime('now')
  )
"
```

Or use a bulk import script to load all workflows.

## Contract Addresses

V6 contracts are deployed on Polygon:
- IntegraDocumentRegistryV6: 0x8609E5627933665D4576aAE992b13465fedecBde
- MultiPartyResolverV6: 0x5D83e8b6caebf6d3eb5ad222592708b7215b36D8
- OwnershipResolverV6: 0x98ec167546ae0cFEDB0955bcD93AC473761ce7FF
- SharesResolverV6: 0xAd0A3e01FA7E7081e5718E2aE5f722eF2849578D
- IntegraMessageV6: 0x0247F6AF7D27988EAfcDA0540B20e79375875D0a
- IntegraSignalV6: 0xbdA381A883C084c5702329f796b95fE44773Fe2D
