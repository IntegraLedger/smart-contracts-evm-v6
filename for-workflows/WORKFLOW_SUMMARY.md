# V6 Workflow Summary

## Quick Reference

| ID | Name | Contract | Type | Version | Function |
|----|------|----------|------|---------|----------|
| register-document | Register Document (V6) | IntegraDocumentRegistry | document-registry | v6.0 | registerDocument |
| register-document-for | Register Document For (V6) | IntegraDocumentRegistry | document-registry | v6.0 | registerDocumentFor |
| set-resolver | Set Resolver (V6) | IntegraDocumentRegistry | document-registry | v6.0 | setResolver |
| set-resolver-for | Set Resolver For (V6) | IntegraDocumentRegistry | document-registry | v6.0 | setResolverFor |
| transfer-document-ownership | Transfer Document Ownership (V6) | IntegraDocumentRegistry | document-registry | v6.0 | transferDocumentOwnership |
| transfer-document-ownership-for | Transfer Document Ownership For (V6) | IntegraDocumentRegistry | document-registry | v6.0 | transferDocumentOwnershipFor |
| reserve-token-anonymous-multiparty | Reserve Token Anonymous (V6) | MultiPartyResolver | resolver | v6.0 | reserveTokenAnonymous |
| reserve-token-anonymous-ownership | Reserve NFT Anonymous (V6) | OwnershipResolver | resolver | v6.0 | reserveTokenAnonymous |
| reserve-token-anonymous-shares | Reserve Shares Anonymous (V6) | SharesResolver | resolver | v6.0 | reserveTokenAnonymous |
| claim-token | Claim Token (V6) | Resolver (all 3) | resolver | v6.0 | claimToken |
| cancel-reservation | Cancel Reservation (V6) | Resolver (all 3) | resolver | v6.0 | cancelReservation |
| declare-primary-wallet | Declare Primary Wallet (V6) | Resolver (all 3) | resolver | v6.0 | declarePrimaryWallet |
| register-message-v6 | Register Message (V6) | IntegraMessage | message | v6.0 | registerMessage |
| send-payment-request-v6 | Send Payment Request (V6) | IntegraSignal | signal | v6.0 | sendPaymentRequest |
| mark-paid | Mark Payment Paid (V6) | IntegraSignal | signal | v6.0 | markPaid |
| cancel-payment-v6 | Cancel Payment (V6) | IntegraSignal | signal | v6.0 | cancelPayment |
| dispute-payment | Dispute Payment (V6) | IntegraSignal | signal | v6.0 | disputePayment |
| resolve-dispute | Resolve Payment Dispute (V6) | IntegraSignal | signal | v6.0 | resolveDispute |

## By Contract Type

**document-registry**: 6 workflows
**resolver**: 6 workflows  
**message**: 1 workflow
**signal**: 5 workflows

**Total**: 18 workflows

## V6 vs V4.5 Differences

| Aspect | V4.5 | V6.0 |
|--------|------|------|
| Document Registry | IntegraLedger (ledger) | IntegraDocumentRegistry (document-registry) |
| Tokenization | IntegraLedger (ledger) | Resolvers (resolver) |
| Access Control | On-chain approvals | EAS attestations |
| Reservations | Named recipients | Anonymous + attestation-based claims |
| Payment Details | On-chain | Encrypted off-chain |
| Trust Graph | Not supported | Primary wallet declarations |

## Next Steps

1. Add V6 contract ABIs to chain registry database (if not already present)
2. Load these workflow definitions into workflow_library database
3. Deploy V6 contracts to additional chains (currently only Polygon)
4. Test workflows end-to-end with V6 contracts
5. Create UI pages for new V6 workflows in trust platform
