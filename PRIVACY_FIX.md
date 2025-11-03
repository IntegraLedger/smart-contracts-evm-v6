# Privacy Fix: Removal of declarePrimaryWallet

**Date**: 2025-11-03
**Severity**: CRITICAL PRIVACY FLAW
**Status**: FIXED (Not Yet Deployed)

---

## The Problem

The V6 resolver contracts (MultiPartyResolverV6, OwnershipResolverV6, SharesResolverV6) included functions that **completely destroyed user privacy**:

```solidity
// PUBLIC mapping - anyone can query
mapping(address => address) public ephemeralToPrimary;

// PUBLIC function - reveals linkage
function declarePrimaryWallet(address primary, bytes memory signature) external

// PUBLIC event - broadcast to all indexers
event PrimaryWalletDeclared(address indexed ephemeral, address indexed primary, ...)
```

### Privacy Impact

**Without this function (privacy preserved):**
- Alice uses ephemeral `0xabc...` for Document A
- Alice uses ephemeral `0xdef...` for Document B
- No one can link these activities to the same person ✅

**With this function (privacy destroyed):**
- Both ephemeral addresses link to `0xPRIMARY` on-chain
- Anyone can query the public mapping
- All activity linkable ❌
- **Complete privacy failure**

---

## Why This Was Wrong

1. **Ephemeral addresses CAN be deterministically linked to primary** - If deterministic derivation exists, off-chain indexers can already attribute credentials without on-chain linkage

2. **The function provided ZERO benefit** - Trust graph can be built off-chain using deterministic derivation

3. **It ONLY caused harm** - Made private linkage public permanently

---

## The Fix

### Code Removed

**From all 3 resolvers (MultiParty, Ownership, Shares):**

1. ❌ Removed `mapping(address => address) public ephemeralToPrimary`
2. ❌ Removed `event PrimaryWalletDeclared(...)`
3. ❌ Removed `function declarePrimaryWallet(...)`
4. ❌ Removed `function getPrimaryWallet(...)`
5. ✅ Changed `_issueCredentialToParty` to issue to ephemeral address directly

**Workflow Removed:**
- ❌ Deleted `declare-primary-wallet.json` workflow

### Correct Architecture

**On-Chain (Smart Contracts):**
- Issue attestations/credentials to ephemeral addresses
- NO ephemeral→primary mapping
- NO linkage published on-chain
- Privacy preserved ✅

**Off-Chain (Indexer/Trust Graph Service):**
- Derive primary wallet from ephemeral (deterministic)
- Aggregate credentials by primary wallet
- Build trust graph privately
- Show users their full credential history
- Privacy preserved ✅

---

## Files Modified

**Smart Contracts:**
- `src/layer3/MultiPartyResolverV6.sol`
- `src/layer3/OwnershipResolverV6.sol`
- `src/layer3/SharesResolverV6.sol`

**Workflows:**
- Deleted: `for-workflows/declare-primary-wallet.json`
- Updated README to reflect 17 workflows (was 18)

---

## Deployment Required

**Contracts to Redeploy:**
1. MultiPartyResolverV6 (Polygon: currently 0x5D83e8b6caebf6d3eb5ad222592708b7215b36D8)
2. OwnershipResolverV6 (Polygon: currently 0x98ec167546ae0cFEDB0955bcD93AC473761ce7FF)
3. SharesResolverV6 (Polygon: currently 0xAd0A3e01FA7E7081e5718E2aE5f722eF2849578D)

**After Redeployment:**
1. Update chain registry database with new addresses
2. Mark old deployments as inactive (is_active = 0)
3. Update documentation with new addresses

---

## Impact Assessment

**Existing Deployments:**
- ⚠️ Current Polygon V6 resolvers have the privacy flaw
- ⚠️ If anyone has called `declarePrimaryWallet`, their linkage is permanently on-chain
- ⚠️ Need to redeploy with fixed contracts ASAP

**Greenfield Status:**
- ✅ Since this is greenfield, likely no one has used the function yet
- ✅ Redeployment will prevent future privacy breaches
- ✅ New contracts will have privacy-preserving design

---

## Lessons Learned

1. **Privacy by Design**: Review every public function/event for privacy implications
2. **Question On-Chain Data**: Ask "does this NEED to be on-chain?"
3. **Off-Chain Attribution**: Many linkages can be done privately off-chain
4. **Deterministic Derivation > On-Chain Mapping**: Use cryptographic derivation instead of storing linkages

---

## Verification Checklist

Before deployment:
- [x] All references to `ephemeralToPrimary` removed
- [x] All references to `declarePrimaryWallet` removed
- [x] All references to `getPrimaryWallet` removed
- [x] Event `PrimaryWalletDeclared` removed
- [x] Contracts compile successfully
- [ ] Contracts deployed to Polygon
- [ ] Chain registry updated with new addresses
- [ ] Old contracts marked inactive
- [ ] Deployment documented

---

## Sign-Off

**Privacy Review**: This fix is CRITICAL for maintaining user privacy.
**Approved By**: ___________
**Deploy Date**: ___________
