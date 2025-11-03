# Integra V6 - Complete Polygon Mainnet Deployment

**Date:** November 2, 2025
**Network:** Polygon Mainnet (Chain ID: 137)
**Deployer/Governor:** 0xDCF24793aAff75cE04904F76dE87E067883ef12a

---

## 🎯 **ALL V6 CONTRACTS DEPLOYED**

### **Layer 2 - Document Registry (Core)**

**IntegraDocumentRegistryV6:**
- **Proxy:** `0x8609E5627933665D4576aAE992b13465fedecBde`
- **Implementation:** `0x1DB0f1F15686945f4cc75996092968fA7d496b3C`
- **Polygonscan:** https://polygonscan.com/address/0x8609E5627933665D4576aAE992b13465fedecBde

---

### **Layer 3 - Tokenization Resolvers**

**OwnershipResolverV6** (ERC-721 - Single Ownership):
- **Proxy:** `0x98ec167546ae0cFEDB0955bcD93AC473761ce7FF`
- **Implementation:** `0x0EB0Cc34d70E9C7CE9793BF38643c11a688b2e2A`
- **Polygonscan:** https://polygonscan.com/address/0x98ec167546ae0cFEDB0955bcD93AC473761ce7FF
- **Token:** IOT-V6 (Integra Ownership Token V6)

**SharesResolverV6** (ERC-20 Votes - Fractional Ownership):
- **Proxy:** `0xAd0A3e01FA7E7081e5718E2aE5f722eF2849578D`
- **Implementation:** `0xEC14826A69cFB488AaDeAB5e76cF679371576640`
- **Polygonscan:** https://polygonscan.com/address/0xAd0A3e01FA7E7081e5718E2aE5f722eF2849578D
- **Token:** ISH-V6 (Integra Shares V6)

**MultiPartyResolverV6** (ERC-1155 - Multi-Stakeholder):
- **Proxy:** `0x5D83e8b6caebf6d3eb5ad222592708b7215b36D8`
- **Implementation:** `0x973c20e1298fC27F34ff7Ce1545e156CCD8012a0`
- **Polygonscan:** https://polygonscan.com/address/0x5D83e8b6caebf6d3eb5ad222592708b7215b36D8

---

### **Layer 4 - Communication**

**IntegraMessageV6** (Workflow Events):
- **Proxy:** `0x0247F6AF7D27988EAfcDA0540B20e79375875D0a`
- **Implementation:** `0x62266f5505AaDcb1a9955791Aa7025e44bFBBf20`
- **Polygonscan:** https://polygonscan.com/address/0x0247F6AF7D27988EAfcDA0540B20e79375875D0a

**IntegraSignalV6** (Payment Requests):
- **Proxy:** `0xbdA381A883C084c5702329f796b95fE44773Fe2D`
- **Implementation:** `0xccCcd68EEF4CBd3D6e13B27fe0E7E979483aD64B`
- **Polygonscan:** https://polygonscan.com/address/0xbdA381A883C084c5702329f796b95fE44773Fe2D

---

### **Layer 6 - Infrastructure**

**IntegraVerifierRegistryV6** (ZK Verifier Management):
- **Proxy:** `0x4A6EBd1f4Ac78A58632f7009f43AB087810335CC`
- **Implementation:** `0xB7666b0354361270f18CA164DffB0efc105F7a6c`
- **Polygonscan:** https://polygonscan.com/address/0x4A6EBd1f4Ac78A58632f7009f43AB087810335CC

**IntegraExecutorV6** (Meta-Transactions):
- **Proxy:** `0x786E015B709F0aAEb655416c4AA4020D66E54d96`
- **Implementation:** `0x6BFE8485aE0eB1D709b97f4c551D76ECD256CAe6`
- **Polygonscan:** https://polygonscan.com/address/0x786E015B709F0aAEb655416c4AA4020D66E54d96

**IntegraTokenGatewayV6:**
- Status: Not deployed (requires Integra token address)

---

## 💰 **Total Deployment Cost:**

| Deployment | Gas Used | Cost (POL) | Cost (USD) |
|------------|----------|------------|------------|
| Layer 2 + Layer 6 (Core) | 6,048,913 | 0.4488 | ~$0.36 |
| Layer 3 (Resolvers) | 20,006,536 | 1.4418 | ~$1.15 |
| Layer 4 + Executor | 8,039,076 | 0.5589 | ~$0.45 |
| **TOTAL** | **34,094,525** | **2.4495 POL** | **~$1.96** |

**Extremely cost-effective deployment on Polygon!**

---

## 🔗 **External Dependencies:**

**EAS (Ethereum Attestation Service):**
- **EAS Contract:** `0x5E634ef5355f45A855d02D66eCD687b1502AF790`
- **Schema Registry:** `0x7876EEF51A891E737AF8ba5A5E0f0Fd29073D5a7`
- **Explorer:** https://polygon.easscan.org/

---

## ⚙️ **Required Configuration:**

### **1. Register EAS Schemas**

Create these schemas at https://polygon.easscan.org/schema/create:

**Access Capability Schema:**
```
bytes32 documentHash, uint256 tokenId, uint256 capabilities, 
string verifiedIdentity, string verificationMethod, uint256 verificationDate,
string contractRole, string legalEntityType, string notes
```

**Credential Schema:**
```
bytes32 credentialHash
```

**Payment Payload Schema:**
```
bytes32 payloadHash
```

### **2. Update Schema UIDs** (after registration)

```solidity
// On each Layer 3 resolver
ownershipResolver.setAccessCapabilitySchema(actualSchemaUID);
sharesResolver.setAccessCapabilitySchema(actualSchemaUID);
multiPartyResolver.setAccessCapabilitySchema(actualSchemaUID);

// On IntegraSignalV6
// (No setter function - schemas are immutable after deployment)
// Redeploy if you need to change payment payload schema
```

### **3. Approve Resolvers on Document Registry**

```solidity
// Call on IntegraDocumentRegistryV6 (0x8609E5627933665D4576aAE992b13465fedecBde)
documentRegistry.setResolverApproval(0x98ec167546ae0cFEDB0955bcD93AC473761ce7FF, true); // OwnershipResolverV6
documentRegistry.setResolverApproval(0xAd0A3e01FA7E7081e5718E2aE5f722eF2849578D, true); // SharesResolverV6
documentRegistry.setResolverApproval(0x5D83e8b6caebf6d3eb5ad222592708b7215b36D8, true); // MultiPartyResolverV6
```

### **4. Register ZK Verifiers** (if using proofs)

```solidity
// Call on IntegraVerifierRegistryV6 (0x4A6EBd1f4Ac78A58632f7009f43AB087810335CC)
verifierRegistry.registerVerifier(
    verifierAddress,
    "BasicAccessV1Poseidon",
    "v1"
);
```

### **5. Configure Executor Allowlists**

```solidity
// Call on IntegraExecutorV6 (0x786E015B709F0aAEb655416c4AA4020D66E54d96)
executor.setTargetAllowed(targetContractAddress, true);
executor.setSelectorAllowed(bytes4(keccak256("functionSignature()")), true);
```

---

## 🔐 **Security Checklist:**

- [ ] **Transfer Governor to Multisig** (Gnosis Safe 3-of-5 recommended)
- [ ] **Grant Backend EXECUTOR_ROLE** (on all contracts)
- [ ] **Register Real EAS Schemas** (replace placeholders)
- [ ] **Approve Production Resolvers** (on document registry)
- [ ] **Register Production Verifiers** (on verifier registry)
- [ ] **Set Up Monitoring** (watch for pause events, failed txs)
- [ ] **Test All Functions** (on testnet first recommended)

---

## 📝 **Quick Reference - All Addresses:**

```javascript
// V6 Polygon Mainnet Addresses
const V6_POLYGON = {
  // Layer 2
  documentRegistry: "0x8609E5627933665D4576aAE992b13465fedecBde",
  
  // Layer 3
  ownershipResolver: "0x98ec167546ae0cFEDB0955bcD93AC473761ce7FF",
  sharesResolver: "0xAd0A3e01FA7E7081e5718E2aE5f722eF2849578D",
  multiPartyResolver: "0x5D83e8b6caebf6d3eb5ad222592708b7215b36D8",
  
  // Layer 4
  message: "0x0247F6AF7D27988EAfcDA0540B20e79375875D0a",
  signal: "0xbdA381A883C084c5702329f796b95fE44773Fe2D",
  
  // Layer 6
  verifierRegistry: "0x4A6EBd1f4Ac78A58632f7009f43AB087810335CC",
  executor: "0x786E015B709F0aAEb655416c4AA4020D66E54d96",
  
  // External
  eas: "0x5E634ef5355f45A855d02D66eCD687b1502AF790",
  schemaRegistry: "0x7876EEF51A891E737AF8ba5A5E0f0Fd29073D5a7"
};
```

---

## ✅ **Deployment Complete!**

**Repository:** https://github.com/IntegraLedger/smart-contracts-evm-v6

**Status:** 🟢 **ALL CORE V6 CONTRACTS LIVE ON POLYGON MAINNET**

Total cost: ~$1.96 (2.45 POL)
