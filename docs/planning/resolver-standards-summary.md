# Integra V6 Resolver Standards - Complete Summary

## Overview

This document provides a comprehensive overview of all **10 resolver contracts** in the Integra V6 architecture:
- **3 existing resolvers** (already implemented)
- **7 new resolvers** (to be implemented)

---

## Existing Resolvers (Already Implemented)

### 1. OwnershipResolverV6 (ERC-721)
**Standard:** ERC-721 (Non-Fungible Tokens)
**Use Case:** Single ownership documents
**Examples:** Real estate deeds, vehicle titles, copyright ownership, exclusive licenses

### 2. SharesResolverV6 (ERC-20 Votes)
**Standard:** ERC-20 with ERC-20Votes extension
**Use Case:** Fractional ownership with checkpoint-based voting/distribution
**Examples:** Investment shares, revenue rights, collective ownership, fund tokens

### 3. MultiPartyResolverV6 (ERC-1155)
**Standard:** ERC-1155 (Multi-Token)
**Use Case:** Multi-stakeholder documents with role-based tokens
**Examples:** Purchase agreements (buyer/seller), leases (tenant/landlord), partnerships

---

## New Resolvers (To Be Implemented)

### 4. SoulboundResolverV6 (ERC-5192)
**Standard:** ERC-5192 (Minimal Soulbound NFTs)
**Key Feature:** Non-transferable tokens permanently bound to recipients
**Transferability:** Locked - cannot be transferred after minting
**Revocation:** No built-in revocation (emergency unlock only)

**Use Cases:**
- Professional licenses (medical, legal, contractor)
- Educational credentials (diplomas, certifications)
- Identity documents (residency proof, age verification)
- Compliance certifications (KYC/AML, accredited investor status)
- Achievement badges (non-revocable awards)

**Why This Standard:**
- Simplest soulbound implementation
- Pure non-transferability guarantee
- Low gas costs
- Emergency unlock for reissuance scenarios

---

### 5. BadgeResolverV6 (ERC-4671)
**Standard:** ERC-4671 (Non-Tradable Tokens with Revocation)
**Key Feature:** Non-transferable badges with lifecycle management
**Transferability:** Non-tradable (no transfer functions exist)
**Revocation:** Yes - badges can be marked invalid while preserving history

**Use Cases:**
- Revocable licenses (driver's licenses, business permits)
- Time-limited certifications (annual safety training, food handler permits)
- Membership badges (DAO/club membership - revocable for violations)
- Event attendance (conference badges, workshop certificates)
- Government documents (marriage certificates - revocable via divorce)
- Product warranties (revocable if voided)

**Key Differences from ERC-5192:**
- Has `isValid()` function for revocation checking
- Historical record preserved after revocation
- Optional "pull" mechanism for wallet migration
- More suitable for credentials with lifecycle states

**Special Features:**
- `hasValid(address)` - check if holder has any valid badges
- Optional pull mechanism - move badges between own addresses
- Batch operations support

---

### 6. VaultResolverV6 (ERC-4626)
**Standard:** ERC-4626 (Tokenized Vaults)
**Key Feature:** Yield-bearing shares with automatic compounding
**Transferability:** Transferable
**Fungibility:** Fungible

**Use Cases:**
- Private equity funds (LP deposits capital, receives fund shares)
- Real Estate Investment Trusts (rental income auto-compounds)
- Revenue sharing agreements (profit pool investments)
- Tokenized bonds/notes (principal + interest accumulation)
- Trust fund management (beneficiary yield earning)
- Yield-bearing document pools (invoice factoring, royalty aggregation)

**Key Interface Methods:**
- `deposit(assets)` / `mint(shares)` - Invest and receive shares
- `withdraw(assets)` / `redeem(shares)` - Exit and retrieve assets
- `convertToShares()` / `convertToAssets()` - Exchange rate queries
- `totalAssets()` - Current vault value (including yield)

**Special Features:**
- Share value appreciates with vault performance
- Standardized across DeFi (composability)
- Lockup period enforcement
- Management/performance fee structures
- Pro-rata distributions

---

### 7. RentalResolverV6 (ERC-4907)
**Standard:** ERC-4907 (Rental NFT)
**Key Feature:** Time-limited user role separate from ownership
**Transferability:** Owner can transfer; User cannot
**Roles:** Owner (has NFT) + User (temporary access rights)

**Use Cases:**
- Residential leases (landlord = owner, tenant = user)
- Commercial leases (property owner vs. business tenant)
- Equipment rentals (construction, medical, vehicles)
- Software/IP licenses (time-limited usage rights)
- Timeshare properties (rotating usage schedules)
- Event access (conference attendance, gym memberships)
- Subscription services (content access, SaaS platforms)
- Gaming assets (in-game item rentals, virtual land leasing)
- Rent-to-own agreements (gradual ownership transfer)

**Key Interface Methods:**
- `setUser(tokenId, user, expires)` - Grant temporary access
- `userOf(tokenId)` - Get current user (returns address(0) if expired)
- `userExpires(tokenId)` - Get expiration timestamp

**Special Features:**
- Automatic expiration (no manual revocation transaction)
- Owner retains transfer rights
- User role cleared on transfer
- Payment tracking for rent collection
- Security deposit escrow
- Rent-to-own conversion logic

---

### 8. RoyaltyResolverV6 (ERC-2981)
**Standard:** ERC-2981 (NFT Royalty Standard)
**Key Feature:** Creator royalties on secondary sales
**Transferability:** Transferable
**Enforcement:** Query interface (voluntary marketplace compliance)

**Use Cases:**
- Intellectual property licensing (patent royalties)
- Creative works (digital art, music composition, photography)
- Revenue rights documents (product royalties, film residuals)
- Real estate appreciation sharing (developer gets % of resales)
- Business sale earnouts (seller gets % of future sales)
- Securitized assets (servicing fees on secondary market)

**Key Interface:**
- `royaltyInfo(tokenId, salePrice)` → (recipient, royaltyAmount)

**Special Features:**
- Percentage-based (constant regardless of price)
- Tiered royalties (different % by transfer count)
- Royalty caps (maximum amount)
- Royalty buyout mechanism
- Split royalties (multiple recipients)

**Note:** ERC-2981 is query-only (doesn't enforce payments on-chain)

---

### 9. SemiFungibleResolverV6 (ERC-3525) **[NEW]**
**Standard:** ERC-3525 (Semi-Fungible Tokens)
**Key Feature:** ID + SLOT + VALUE model - fungible within slots, unique across slots
**Transferability:** Transferable, splittable, mergeable
**Fungibility:** Semi-fungible (fungible within same SLOT)

**The ID-SLOT-VALUE Model:**
```
Token #123:
  ID: 123 (unique identifier, like ERC-721)
  SLOT: "2025-Q4-Bond-Series-A" (category/type)
  VALUE: 10,000 (quantity, like ERC-20 balance)

Token #456:
  ID: 456 (different token)
  SLOT: "2025-Q4-Bond-Series-A" (SAME slot)
  VALUE: 5,000 (different amount)

→ Tokens #123 and #456 are FUNGIBLE (can split/merge)
→ Can transfer 3,000 VALUE from #123 to #456
→ Result: Token #123 = 7,000, Token #456 = 8,000
```

**Use Cases:**
1. **Bonds with Different Amounts**
   - SLOT = Bond series (maturity date, coupon rate)
   - VALUE = Bond face value
   - Investors can split/combine bond holdings

2. **Vesting Plans with Tranches**
   - SLOT = Vesting schedule ("4-year-monthly", "immediate")
   - VALUE = Number of tokens vesting
   - Can transfer portions while maintaining vesting terms

3. **Insurance Policies**
   - SLOT = Policy type (coverage terms)
   - VALUE = Coverage amount
   - Split policies for partial coverage transfers

4. **Mortgages & Loans**
   - SLOT = Loan terms (interest rate, maturity)
   - VALUE = Loan principal amount
   - Enable fractional loan ownership

5. **Invoice Factoring**
   - SLOT = Invoice due date
   - VALUE = Invoice amount
   - Factor can buy portions of invoices

6. **Structured Products**
   - SLOT = Tranche (Senior, Mezzanine, Equity)
   - VALUE = Investment amount
   - Different risk/return profiles per slot

**Key Operations:**
- `transferFrom(fromTokenId, toTokenId, value)` - Move value between tokens in same SLOT
- `transferFrom(fromTokenId, address, value)` - Transfer value to address (creates/finds token)
- `balanceOf(tokenId)` - Get token's VALUE
- `slotOf(tokenId)` - Get token's SLOT
- **Split:** Transfer partial VALUE from one token to another
- **Merge:** Combine VALUE from multiple tokens into one

**Why Better than ERC-1155:**
- ERC-1155 can't split tokens (all or nothing transfers)
- ERC-3525 enables partial value transfers
- Perfect for financial instruments with variable amounts
- More flexible than pure fungible or non-fungible

**Special Features:**
- Slot-level approvals (approve all tokens in a slot)
- Value-level approvals (approve specific amounts)
- Backward compatible with ERC-721
- Metadata per slot AND per token ID

---

### 10. SecurityTokenResolverV6 (ERC-3643) **[REPLACES ERC-1400]**
**Standard:** ERC-3643 (T-REX - Token for Regulated Exchanges)
**Status:** **Final ERC Standard** (officially accepted, unlike ERC-1400)
**Key Feature:** Institutional-grade security tokens with programmatic compliance
**Transferability:** Restricted (compliance-gated)
**Adoption:** **$28 billion in assets** already tokenized

**Why ERC-3643 Instead of ERC-1400:**

| Feature | ERC-3643 | ERC-1400 |
|---------|----------|----------|
| **Status** | Final ERC Standard ✅ | Draft/Stagnant ❌ |
| **Adoption** | $28B assets tokenized | Lower adoption |
| **Maintenance** | ERC-3643 Association | Polymath (moved to Polymesh) |
| **Identity** | Built-in ONCHAINID framework | External whitelists |
| **Compliance** | Programmatic denial (impossible to transfer if non-compliant) | Reason codes (query-based) |
| **Architecture** | Modular (6 contracts working together) | Monolithic with partitions |
| **Complexity** | Medium | Very High |
| **Real-world Use** | Production-ready, widely deployed | More theoretical |

**Component Architecture:**

ERC-3643 is modular, consisting of 6 interconnected contracts:

1. **Token Contract (IERC3643)**
   - Extended ERC-20 with compliance hooks
   - Methods: `transfer()`, `transferFrom()`, `forcedTransfer()`, `mint()`, `burn()`
   - Freeze controls: `setAddressFrozen()`, `freezePartialTokens()`
   - Recovery: `recoveryAddress()` for lost private keys

2. **Identity Registry (IIdentityRegistry)**
   - Manages investor whitelist
   - Links wallet → ONCHAINID identity contract
   - Stores ISO-3166 country codes
   - Method: `isVerified()` - validates investor claims

3. **Identity Registry Storage (IIdentityRegistryStorage)**
   - Separates data from logic
   - Can be shared across multiple token deployments
   - Enables unified investor whitelists

4. **Compliance Contract (ICompliance)**
   - Enforces offering rules (independent of individual eligibility)
   - Method: `canTransfer()` - pre-transfer compliance check
   - Rules: Max investors per country, token concentration limits

5. **Trusted Issuers Registry (ITrustedIssuersRegistry)**
   - Manages authorized claim signers (KYC/AML providers)
   - Associates claim topics with issuers
   - Only approved issuers can verify investor status

6. **Claim Topics Registry (IClaimTopicsRegistry)**
   - Defines required investor credentials
   - Examples: KYC verified, accredited investor, location proof

**ONCHAINID Framework:**

Built-in decentralized identity system:
- **Identity Contract:** One per investor, stores claims
- **Claim:** Signed attestation from trusted issuer (e.g., "KYC verified by Chainalysis")
- **Claim Holder:** Smart contract evaluating claim validity

**Transfer Validation Flow:**

Every transfer must pass ALL checks:
1. ✅ Sender has sufficient unfrozen balance
2. ✅ Sender's wallet not frozen
3. ✅ Receiver whitelisted in Identity Registry
4. ✅ Receiver has required claims from trusted issuers
5. ✅ Token contract not paused
6. ✅ Compliance rules satisfied (`canTransfer()` returns true)
7. ✅ Country/jurisdiction restrictions met

**If ANY check fails → transfer reverts**

**Use Cases:**
1. **Private Securities Offerings**
   - Reg D offerings (accredited investors only)
   - Reg S offerings (offshore investors)
   - Reg A+ offerings (broader access with holder limits)

2. **Equity Token Issuance**
   - Common stock with transfer restrictions
   - Preferred stock with different rights per class
   - Stock options (subject to vesting)
   - RSUs and ESOPs

3. **Debt Securities**
   - Corporate bonds with holder caps
   - Convertible notes (conversion restrictions)
   - Asset-backed securities (compliance by tranche)

4. **Fund Tokens**
   - Private equity fund shares
   - Hedge fund interests (qualified purchasers only)
   - Venture capital tokens
   - Real estate fund shares

5. **Real Estate Securities**
   - REIT shares with KYC/AML
   - Property tokens with jurisdiction limits
   - Fractional ownership with compliance

**Agent Roles:**

Agents perform operational tasks delegated by token owner:
- Mint/burn tokens
- Execute forced transfers (court orders, compliance)
- Manage frozen addresses
- Update compliance settings
- Modify identity registry

**Special Features:**
- **Batch operations** for gas efficiency
- **Pause functionality** for emergencies
- **Recovery mechanism** for lost private keys
- **Partial token freezing** (freeze portion of balance)
- **Address-level freezing** (freeze entire wallet)
- **Pre-transfer validation** (`canTransfer()` prevents failed transactions)

**Compliance Examples:**

**Scenario 1: Accredited Investor Requirement**
```
1. Token requires claim topic #1 (Accredited Investor)
2. Trusted Issuer = "SEC Verification Service"
3. Investor must have claim #1 signed by SEC Verification Service
4. Without valid claim → transfer reverts
```

**Scenario 2: Geographic Restrictions**
```
1. Token restricted to US + EU investors
2. Identity Registry stores country code per investor
3. Compliance contract checks country restrictions
4. Transfer to non-US/EU investor → reverts
```

**Scenario 3: Holder Limits**
```
1. Regulation limits to 2,000 holders
2. Compliance tracks current holder count
3. New investor would exceed limit → transfer reverts
4. Existing investor buying more → allowed
```

**Integration with Integra V6:**
- Anonymous reservations per compliance tier
- Attestation-based claiming (after KYC/AML)
- Encrypted labels for investor classes
- Trust graph integration for compliance credentials
- Document management for offering memorandums

---

## Comparison Matrix: All 10 Resolvers

| Resolver | Standard | Transferable | Fungible | Key Feature | Use Case Category | Complexity | Gas Cost |
|----------|----------|--------------|----------|-------------|-------------------|------------|----------|
| **OwnershipResolverV6** | ERC-721 | Yes | No | Single ownership NFT | Property rights | Low | ~100k |
| **SharesResolverV6** | ERC-20 Votes | Yes | Yes | Checkpoint-based shares | Investments | Medium | ~120k |
| **MultiPartyResolverV6** | ERC-1155 | Yes | Semi | Role-based tokens | Multi-party docs | Medium | ~110k |
| **SoulboundResolverV6** | ERC-5192 | No | No | Locked NFT | Credentials | Low | ~90k |
| **BadgeResolverV6** | ERC-4671 | No | No | Revocable badges | Licenses | Medium | ~95k |
| **VaultResolverV6** | ERC-4626 | Yes | Yes | Yield-bearing shares | Investment funds | High | ~180k |
| **RentalResolverV6** | ERC-4907 | Owner: Yes<br>User: No | No | Time-limited user | Leases/rentals | Medium | ~120k |
| **RoyaltyResolverV6** | ERC-2981 | Yes | No | Creator royalties | IP licensing | Low | ~95k |
| **SemiFungibleResolverV6** | ERC-3525 | Yes | Semi | ID+SLOT+VALUE | Financial instruments | High | ~150k |
| **SecurityTokenResolverV6** | ERC-3643 | Restricted | Yes | Compliance-gated | Regulated securities | Very High | ~200k |

---

## Resolver Selection Guide

### For Credentials & Achievements

- **Permanent, non-revocable** → SoulboundResolverV6 (ERC-5192)
- **Revocable, time-limited** → BadgeResolverV6 (ERC-4671)

### For Investments

- **Simple ownership shares** → SharesResolverV6 (ERC-20 Votes)
- **Yield-bearing funds** → VaultResolverV6 (ERC-4626)
- **Variable-amount financial instruments** → SemiFungibleResolverV6 (ERC-3525)
- **Regulated securities** → SecurityTokenResolverV6 (ERC-3643)

### For Rentals & Leases

- **Time-limited usage rights** → RentalResolverV6 (ERC-4907)

### For Property & IP

- **Single ownership** → OwnershipResolverV6 (ERC-721)
- **With ongoing royalties** → RoyaltyResolverV6 (ERC-2981)

### For Multi-Party Documents

- **Role-based participation** → MultiPartyResolverV6 (ERC-1155)

---

## Implementation Priority Recommendation

### Phase 1: Core Credentials & Investments (Highest ROI)
1. **SoulboundResolverV6** (ERC-5192) - Simple, high demand
2. **BadgeResolverV6** (ERC-4671) - Revocable credentials
3. **VaultResolverV6** (ERC-4626) - DeFi integration
4. **SemiFungibleResolverV6** (ERC-3525) - Unique differentiator

### Phase 2: Leases & Royalties
5. **RentalResolverV6** (ERC-4907) - Real estate focus
6. **RoyaltyResolverV6** (ERC-2981) - IP/creative economy

### Phase 3: Advanced & Regulatory
7. **SecurityTokenResolverV6** (ERC-3643) - Regulatory compliance (most complex)

---

## Final Resolver Count

**Total: 10 Resolvers**

**Existing (3):**
1. OwnershipResolverV6 (ERC-721)
2. SharesResolverV6 (ERC-20 Votes)
3. MultiPartyResolverV6 (ERC-1155)

**New (7):**
4. SoulboundResolverV6 (ERC-5192)
5. BadgeResolverV6 (ERC-4671)
6. VaultResolverV6 (ERC-4626)
7. RentalResolverV6 (ERC-4907)
8. RoyaltyResolverV6 (ERC-2981)
9. SemiFungibleResolverV6 (ERC-3525)
10. SecurityTokenResolverV6 (ERC-3643)

**Coverage:** Complete spectrum of document tokenization needs from credentials to regulated securities.

---

**Document Version:** 3.1
**Last Updated:** 2025-11-04
**Status:** Final Resolver List

**Changelog:**
- v3.1: Removed ERC-5114 (final count: 7 new resolvers, 10 total)
- v3.0: Replaced ERC-1400 with ERC-3643, added ERC-3525 and ERC-5114 (8 total new resolvers)
- v2.0: Added ERC-4671 and ERC-1400 (6 total new resolvers)
- v1.0: Initial version with 4 resolvers
