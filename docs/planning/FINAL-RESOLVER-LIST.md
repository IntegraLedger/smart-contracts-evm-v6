# Integra V6 - Final Resolver List

## Total: 11 Resolvers

### Existing (3):
1. **OwnershipResolverV6** (ERC-721)
2. **SharesResolverV6** (ERC-20 Votes)
3. **MultiPartyResolverV6** (ERC-1155)

### New - To Be Implemented (8):

4. **SoulboundResolverV6** (ERC-5192)
   - Non-transferable credentials
   - Permanently locked to recipient
   - Use: Diplomas, licenses, identity documents

5. **BadgeResolverV6** (ERC-4671)
   - Non-transferable badges with revocation
   - `isValid()` lifecycle management
   - Use: Revocable licenses, memberships, certifications

6. **MultiPartyResolverV6-Lite** (ERC-6909) **[NEW]**
   - Gas-optimized multi-token standard
   - 50% cheaper than ERC-1155
   - No mandatory callbacks
   - Use: High-volume multi-party documents

7. **VaultResolverV6** (ERC-4626)
   - Yield-bearing investment shares
   - Automatic compounding
   - Use: Private equity, REITs, investment funds

8. **RentalResolverV6** (ERC-4907)
   - Time-limited user role
   - Owner vs User separation
   - Use: Leases, equipment rentals, subscriptions

9. **RoyaltyResolverV6** (ERC-2981)
   - Creator royalties on resales
   - Percentage-based payments
   - Use: IP licensing, creative works, revenue rights

10. **SemiFungibleResolverV6** (ERC-3525)
    - ID + SLOT + VALUE model
    - Split/merge within same slot
    - Use: Bonds, structured products, fractional ownership

11. **SecurityTokenResolverV6** (ERC-3643) **[REPLACES ERC-1400]**
    - Official Final ERC Standard
    - Programmatic compliance with ONCHAINID
    - $28B in assets already tokenized
    - Use: Regulated securities, compliant equity/debt tokens

---

## Key Updates from Previous Versions

✅ **Added ERC-6909** - Gas-efficient alternative to ERC-1155
✅ **Replaced ERC-1400 with ERC-3643** - Official standard vs stagnant draft
❌ **Removed ERC-5114** - NFT-bound badges not needed

---

## ERC-3643 Details (SecurityTokenResolverV6)

### Why ERC-3643 Instead of ERC-1400?

| Factor | ERC-3643 | ERC-1400 |
|--------|----------|----------|
| **Status** | ✅ Final ERC Standard | ❌ Draft/Stagnant |
| **Adoption** | ✅ $28 Billion tokenized | Lower |
| **Maintenance** | ✅ ERC-3643 Association | Polymath (moved to Polymesh) |
| **Identity System** | ✅ Built-in ONCHAINID | External whitelists |
| **Compliance** | ✅ Programmatic denial | Reason codes only |
| **Architecture** | ✅ Modular (6 contracts) | Monolithic partitions |

### ERC-3643 Component Architecture

1. **Token Contract** - Extended ERC-20 with compliance hooks
2. **Identity Registry** - Investor whitelist + ONCHAINID linkage
3. **Identity Registry Storage** - Shared investor data
4. **Compliance Contract** - Offering rules (holder limits, etc.)
5. **Trusted Issuers Registry** - Authorized KYC/AML providers
6. **Claim Topics Registry** - Required credentials

### Key Interface Methods

```solidity
// Token operations
function transfer(address to, uint256 amount) external returns (bool);
function forcedTransfer(address from, address to, uint256 amount) external;
function mint(address to, uint256 amount) external;
function burn(address from, uint256 amount) external;

// Compliance freezing
function setAddressFrozen(address addr, bool freeze) external;
function freezePartialTokens(address addr, uint256 amount) external;

// Recovery
function recoveryAddress(address lostWallet, address newWallet) external;

// Batch operations
function batchTransfer(address[] calldata to, uint256[] calldata amounts) external;
function batchForcedTransfer(address[] calldata from, address[] calldata to, uint256[] calldata amounts) external;

// Identity Registry
function isVerified(address addr) external view returns (bool);
function registerIdentity(address user, address identity, uint16 country) external;

// Compliance
function canTransfer(address from, address to, uint256 amount) external view returns (bool);
```

### Transfer Validation Flow

Every transfer must pass:
1. ✅ Sender has sufficient unfrozen balance
2. ✅ Sender wallet not frozen
3. ✅ Receiver whitelisted in Identity Registry
4. ✅ Receiver has required claims from trusted issuers
5. ✅ Token not paused
6. ✅ Compliance rules satisfied
7. ✅ Jurisdiction restrictions met

**If ANY check fails → transfer reverts automatically**

### ONCHAINID Framework

- **Identity Contract**: One per investor, stores claims
- **Claim**: Signed attestation (e.g., "KYC verified by Chainalysis")
- **Claim Issuer**: Trusted KYC/AML provider
- **Claim Topics**: Required credentials (accredited investor, location, etc.)

### Integra V6 Integration

```solidity
struct SecurityTokenData {
    bytes32 integraHash;

    // Identity & Compliance
    address identityRegistry;
    address compliance;
    address trustedIssuersRegistry;
    address claimTopicsRegistry;

    // Agent controls
    address controller;
    mapping(address => bool) agents;

    // Freezing
    mapping(address => bool) frozen;
    mapping(address => uint256) frozenTokens;

    // Integra-specific
    mapping(address => uint256) reservations;
    mapping(address => bool) claimed;
    bytes encryptedLabel;
}
```

### Use Cases

1. **Private Securities** - Reg D, Reg S, Reg A+ offerings
2. **Equity Tokens** - Common/preferred stock with restrictions
3. **Debt Securities** - Bonds, convertible notes
4. **Fund Tokens** - PE, VC, hedge fund shares
5. **Real Estate Securities** - REIT tokens with compliance

---

## ERC-6909 Details (MultiPartyResolverV6-Lite)

### Why ERC-6909?

**Gas Savings vs ERC-1155:**
- Transfer: 50% cheaper (~50k vs ~100k gas)
- Mint: 40% cheaper
- No mandatory callbacks (biggest savings)

**Proven in Production:**
- Used by Uniswap V4
- Battle-tested in high-volume DeFi

### Key Differences from ERC-1155

| Feature | ERC-1155 | ERC-6909 |
|---------|----------|----------|
| **Callbacks** | Mandatory | Optional |
| **Batch Transfers** | Built-in | Custom implementation |
| **Approvals** | Operator-only | Hybrid (operator + allowance) |
| **Gas Cost** | Higher | 50% cheaper |
| **Complexity** | Higher | Simpler |

### Interface

```solidity
// Core transfers
function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool);

// Approvals (hybrid system)
function approve(address spender, uint256 id, uint256 amount) external returns (bool);
function setOperator(address operator, bool approved) external returns (bool);

// Queries
function balanceOf(address owner, uint256 id) external view returns (uint256);
function allowance(address owner, address spender, uint256 id) external view returns (uint256);
function isOperator(address owner, address operator) external view returns (bool);
```

### When to Use ERC-6909 vs ERC-1155

**Use ERC-6909 when:**
- High-volume document issuance (gas costs matter)
- Simple multi-party documents (no complex callbacks needed)
- You want Uniswap V4-level gas optimization

**Use ERC-1155 when:**
- Need mandatory recipient validation (callbacks)
- Want built-in batch transfers
- Ecosystem tooling compatibility more important than gas

**Integra Recommendation:**
- Implement **both**
- Let issuers choose based on volume/cost priorities
- ERC-6909 as "premium gas-efficient" option

---

## Implementation Priority

### Phase 1: Core (Weeks 1-4)
1. SoulboundResolverV6 (ERC-5192) - 1 week
2. BadgeResolverV6 (ERC-4671) - 1 week
3. RoyaltyResolverV6 (ERC-2981) - 1 week
4. MultiPartyResolverV6-Lite (ERC-6909) - 1 week

### Phase 2: Investments & Leases (Weeks 5-7)
5. VaultResolverV6 (ERC-4626) - 2 weeks
6. RentalResolverV6 (ERC-4907) - 1 week

### Phase 3: Advanced (Weeks 8-13)
7. SemiFungibleResolverV6 (ERC-3525) - 2 weeks
8. SecurityTokenResolverV6 (ERC-3643) - 3 weeks

**Total: ~13 weeks for all 8 new resolvers**

---

## Gas Cost Comparison

| Resolver | Standard | Mint Gas | Transfer Gas |
|----------|----------|----------|--------------|
| OwnershipResolverV6 | ERC-721 | ~100k | ~80k |
| SharesResolverV6 | ERC-20 | ~120k | ~70k |
| MultiPartyResolverV6 | ERC-1155 | ~110k | ~100k |
| **MultiPartyResolverV6-Lite** | **ERC-6909** | **~65k** | **~50k** |
| SoulboundResolverV6 | ERC-5192 | ~90k | N/A (locked) |
| BadgeResolverV6 | ERC-4671 | ~95k | N/A (non-tradable) |
| VaultResolverV6 | ERC-4626 | ~180k | ~120k |
| RentalResolverV6 | ERC-4907 | ~120k | ~85k |
| RoyaltyResolverV6 | ERC-2981 | ~95k | ~100k |
| SemiFungibleResolverV6 | ERC-3525 | ~150k | ~120k |
| SecurityTokenResolverV6 | ERC-3643 | ~200k | ~180k |

---

## Registry Updates Required

```solidity
// In IntegraRegistryV6
enum ResolverType {
    OWNERSHIP,              // ERC-721
    SHARES,                 // ERC-20 Votes
    MULTIPARTY,             // ERC-1155
    MULTIPARTY_LITE,        // ERC-6909 (new)
    SOULBOUND,              // ERC-5192
    BADGE,                  // ERC-4671
    VAULT,                  // ERC-4626
    RENTAL,                 // ERC-4907
    ROYALTY,                // ERC-2981
    SEMIFUNGIBLE,           // ERC-3525
    SECURITY_TOKEN          // ERC-3643
}
```

---

## Decision: Keep Both ERC-1155 and ERC-6909?

**Yes - Recommended to keep both:**

- **ERC-1155 (MultiPartyResolverV6)** - Already implemented, proven standard
- **ERC-6909 (MultiPartyResolverV6-Lite)** - New gas-efficient option

Let issuers choose based on:
- Volume (high volume → ERC-6909 for 50% savings)
- Tooling compatibility (ecosystem support → ERC-1155)
- Cost sensitivity (price-conscious → ERC-6909)

---

**Document Version:** 4.0
**Last Updated:** 2025-11-04
**Status:** FINAL - Ready for Implementation

**Summary:**
- 11 total resolvers (3 existing + 8 new)
- ERC-3643 replaces ERC-1400 (official standard)
- ERC-6909 added (gas optimization)
- ERC-5114 removed (not needed)
- All specifications complete and ready to implement
