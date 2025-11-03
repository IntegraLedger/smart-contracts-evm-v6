# Integra V6 - Polygon Mainnet Deployment

**Deployment Date:** November 2, 2025
**Chain:** Polygon Mainnet (Chain ID: 137)
**Deployer:** 0xDCF24793aAff75cE04904F76dE87E067883ef12a
**Gas Used:** 6,048,913 gas
**Cost:** 0.4488 POL (~$0.36 @ $0.80/POL)

---

## 🎉 **Deployed Contracts**

### **Layer 6 - Infrastructure**

#### IntegraVerifierRegistryV6
```
Proxy (Use This):        0x4A6EBd1f4Ac78A58632f7009f43AB087810335CC
Implementation:          0xB7666b0354361270f18CA164DffB0efc105F7a6c

Polygonscan (Proxy):     https://polygonscan.com/address/0x4A6EBd1f4Ac78A58632f7009f43AB087810335CC
Polygonscan (Impl):      https://polygonscan.com/address/0xB7666b0354361270f18CA164DffB0efc105F7a6c
```

**Functions:**
- `registerVerifier(address, string circuitType, string version)` - Register ZK verifiers
- `getVerifier(bytes32 verifierId)` - Get verifier address
- `pause()` / `unpause()` - Emergency controls

---

### **Layer 2 - Document Registry**

#### IntegraDocumentRegistryV6
```
Proxy (Use This):        0x8609E5627933665D4576aAE992b13465fedecBde
Implementation:          0x1DB0f1F15686945f4cc75996092968fA7d496b3C

Polygonscan (Proxy):     https://polygonscan.com/address/0x8609E5627933665D4576aAE992b13465fedecBde
Polygonscan (Impl):      https://polygonscan.com/address/0x1DB0f1F15686945f4cc75996092968fA7d496b3C
```

**Functions:**
- `registerDocument(...)` - Register document (direct user call)
- `registerDocumentFor(address owner, ...)` - Register via backend (executor call)
- `setResolver(bytes32 integraHash, address resolver)` - Change tokenization strategy
- `transferDocumentOwnership(...)` - Transfer document ownership
- `pause()` / `unpause()` - Emergency controls

---

## 🔑 **Access Control**

**Governor Address:** 0xDCF24793aAff75cE04904F76dE87E067883ef12a

**Roles Granted to Governor:**
- `DEFAULT_ADMIN_ROLE` - Can grant/revoke all roles
- `GOVERNOR_ROLE` - Can upgrade contracts, pause, approve resolvers
- `OPERATOR_ROLE` - Can register verifiers, perform operations
- `EXECUTOR_ROLE` - Can call ...For() functions (backend calls)

---

## 📋 **Post-Deployment Tasks**

### **Required Before Use:**

1. **Register ZK Verifiers:**
   ```solidity
   // Call on IntegraVerifierRegistryV6
   registerVerifier(
       verifierAddress,
       "BasicAccessV1Poseidon",
       "v1"
   );
   ```

2. **Approve Resolvers:**
   ```solidity
   // Call on IntegraDocumentRegistryV6
   setResolverApproval(resolverAddress, true);
   ```

   You'll need to deploy Layer 3 resolvers first:
   - OwnershipResolverV6 (ERC-721 for single ownership)
   - SharesResolverV6 (ERC-20 Votes for fractional shares)
   - MultiPartyResolverV6 (ERC-1155 for multi-party documents)

3. **Grant Backend Executor Role:**
   ```solidity
   // If you have a different backend address
   grantRole(EXECUTOR_ROLE, backendAddress);
   ```

### **Optional:**

4. **Verify Contracts on Polygonscan:**
   - Need to set POLYGONSCAN_API_KEY in .env
   - Run: `forge verify-contract <address> <contract> --chain polygon`

5. **Transfer Governor to Multisig:**
   ```solidity
   // SECURITY: Move governor to Gnosis Safe (3-of-5 recommended)
   grantRole(GOVERNOR_ROLE, multisigAddress);
   renounceRole(GOVERNOR_ROLE, deployerAddress);
   ```

---

## 🔍 **Contract Verification**

**Status:** ⏳ Pending (POLYGONSCAN_API_KEY not set)

**To Verify Manually:**
1. Go to Polygonscan contract page
2. Click "Contract" → "Verify and Publish"
3. Select "Solidity (Single File)" or use Foundry verification
4. Upload flattened source code

**Or use Foundry (once API key added):**
```bash
forge verify-contract \
  0x4A6EBd1f4Ac78A58632f7009f43AB087810335CC \
  src/layer6/IntegraVerifierRegistryV6.sol:IntegraVerifierRegistryV6 \
  --chain polygon \
  --constructor-args $(cast abi-encode "constructor()" )
```

---

## 📊 **Gas Costs**

| Operation | Gas Used |
|-----------|----------|
| Deploy IntegraVerifierRegistryV6 Impl | ~1,650,890 |
| Deploy IntegraVerifierRegistryV6 Proxy | ~288,213 |
| Deploy IntegraDocumentRegistryV6 Impl | ~2,470,206 |
| Deploy IntegraDocumentRegistryV6 Proxy | ~288,213 |
| **Total** | **6,048,913** |

**Total Cost:** 0.4488 POL @ 74 gwei (~$0.36 @ $0.80/POL)

---

## 🔐 **Security Notes**

**IMPORTANT:**
- ✅ All contracts are UUPS upgradeable (only GOVERNOR can upgrade)
- ✅ All contracts have emergency pause functionality
- ✅ All roles initially granted to deployer (0xDCF24793aAff75cE04904F76dE87E067883ef12a)
- ⚠️ **Move GOVERNOR_ROLE to multisig ASAP for production security**
- ✅ Reentrancy protection on all state-changing functions
- ✅ Input validation with MAX_* limits
- ✅ Enhanced error messages for debugging

---

## 📝 **Integration Guide**

### **For Frontend/Backend:**

```javascript
// Document Registry Contract
const documentRegistry = new ethers.Contract(
  '0x8609E5627933665D4576aAE992b13465fedecBde',
  IntegraDocumentRegistryV6ABI,
  signer
);

// Register a document (direct user call)
await documentRegistry.registerDocument(
  integraHash,
  documentHash,
  resolverAddress,
  referencedDocument,
  proofA, proofB, proofC,
  encryptedContactData
);

// Or via backend (executor call - you pay gas)
await documentRegistry.registerDocumentFor(
  userAddress,  // User becomes owner
  integraHash,
  documentHash,
  resolverAddress,
  referencedDocument,
  proofA, proofB, proofC,
  encryptedContactData
);
```

---

## 🚀 **Next Deployments Needed**

To have a fully functional system, deploy:

**Layer 3 - Resolvers** (depends on EAS address on Polygon):
- OwnershipResolverV6
- SharesResolverV6
- MultiPartyResolverV6

**Layer 4 - Communication:**
- IntegraMessageV6
- IntegraSignalV6

**Layer 6 - Additional Infrastructure:**
- IntegraExecutorV6 (for meta-transactions)
- IntegraTokenGatewayV6 (for fee collection, needs Integra token address)

**EAS Contract on Polygon:**
- Address needed for Layer 3 resolver deployments
- Check: https://docs.attest.org/docs/quick--start/contracts

---

## ✅ **Deployment Complete**

The core V6 infrastructure is now live on Polygon Mainnet!

**What's Deployed:**
- ✅ Verifier Registry (manage ZK proof verifiers)
- ✅ Document Registry (core document identity system)

**What's Next:**
- Deploy resolvers (tokenization strategies)
- Deploy communication layer
- Register verifiers
- Approve resolvers
- Transfer governance to multisig

**Repository:** https://github.com/IntegraLedger/smart-contracts-evm-v6
**Network:** Polygon Mainnet
**Status:** 🟢 **LIVE AND OPERATIONAL**
