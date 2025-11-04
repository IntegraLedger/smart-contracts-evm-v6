# Additional Resolver Implementation Plan

## Executive Summary

This document outlines the implementation plan for **seven additional Layer 3 resolver contracts** that extend Integra's V6 document tokenization architecture with specialized token standards. These resolvers address specific use cases not covered by the existing OwnershipResolver (ERC-721), SharesResolver (ERC-20), and MultiPartyResolver (ERC-1155).

**Key Update:** This plan now includes **ERC-3643** (official security token standard) replacing ERC-1400, and **ERC-3525** (semi-fungible tokens for financial instruments) in addition to the originally planned standards.

## Current Resolver Overview

### Existing V6 Resolvers

1. **OwnershipResolverV6** (ERC-721)
   - Single ownership documents
   - Use cases: Deeds, titles, exclusive licenses

2. **SharesResolverV6** (ERC-20 Votes)
   - Fractional ownership with checkpoints
   - Use cases: Investment shares, revenue rights, collective ownership

3. **MultiPartyResolverV6** (ERC-1155)
   - Multi-stakeholder documents
   - Use cases: Purchase agreements, leases, partnerships

### V6 Architecture Principles

All V6 resolvers share these core features:
- **Anonymous reservations** - Address unknown at reservation time
- **Encrypted labels** - Document metadata encrypted with integraID
- **Attestation-based access control** - No ZK proofs required
- **Simplified two-step workflow** - Reserve → Claim (no request/approve)
- **Trust graph integration** - Anonymous credential issuance on completion
- **AttestationAccessControlV6** inheritance
- **IDocumentResolver** interface implementation

---

## New Resolver Standards

### 1. SoulboundResolverV6 (ERC-5192)

#### Standard Overview

ERC-5192 extends ERC-721 to create non-transferable tokens that are permanently bound to their recipients. The standard introduces a `locked()` function that returns whether a token can be transferred.

**Key Interface Methods:**
```solidity
function locked(uint256 tokenId) external view returns (bool);
event Locked(uint256 tokenId);
event Unlocked(uint256 tokenId);
```

When `locked()` returns true, all ERC-721 transfer functions MUST revert.

#### Integra Use Cases

**Primary Use Cases:**
1. **Professional Licenses**
   - Medical licenses (non-transferable, bound to practitioner)
   - Legal bar admissions
   - Contractor licenses and certifications
   - Security clearances

2. **Educational Credentials**
   - University diplomas
   - Training certificates
   - Professional certifications (CPA, PE, etc.)
   - Continuing education credits

3. **Identity Documents**
   - Proof of residency (bound to specific person)
   - Age verification credentials
   - Citizenship/visa documents
   - Background check certificates

4. **Compliance Certifications**
   - KYC/AML verification badges
   - Accredited investor status
   - Regulatory compliance certificates
   - Audit completion certificates

5. **Achievement Badges**
   - Employee of the month awards
   - Milestone completions
   - Security training completions
   - Corporate achievement recognition

#### Workflow Design

**Anonymous Reservation Flow:**
```
1. Issuer reserves soulbound token with encrypted label
   - Label: "Professional Engineer License - Mechanical - California"
   - Address unknown at reservation time

2. Recipient verifies identity off-chain
   - Email verification, video call, document submission
   - Issuer validates credentials

3. Issuer issues capability attestation via EAS
   - Attestation grants CAPABILITY_CLAIM_TOKEN
   - Attestation includes recipient address

4. Recipient claims token
   - Token minted and immediately locked
   - CANNOT be transferred after claiming

5. Trust credential issued
   - Anonymous credential proves license ownership
   - Accumulates at primary wallet
```

#### Architecture Design

**Key Features:**
- Inherits from `ERC721Upgradeable` + `AttestationAccessControlV6`
- Implements `IDocumentResolver` + `IERC5192`
- All tokens locked by default upon minting
- Optional unlock capability (for emergency revocation/reissuance)
- Encrypted labels for credential details

**State Variables:**
```solidity
struct SoulboundTokenData {
    bytes32 integraHash;        // Document identifier
    address owner;              // Bound to this address
    bool minted;                // Prevents double minting
    bool locked;                // Transfer lock status (always true)
    bytes encryptedLabel;       // Credential details
    uint256 issuanceDate;       // When token was claimed
    uint256 expirationDate;     // Optional expiration (0 = no expiry)
}
```

**Special Considerations:**
- Override all ERC-721 transfer functions to check `locked()` status
- Implement emergency unlock for reissuance (GOVERNOR_ROLE only)
- Add expiration checking for time-limited credentials
- Integrate with trust graph for credential verification

---

### 2. VaultResolverV6 (ERC-4626)

#### Standard Overview

ERC-4626 establishes a standardized interface for yield-bearing vault contracts. It extends ERC-20 to represent vault shares, enabling consistent integration across DeFi protocols.

**Key Interface Methods:**
```solidity
// Conversion
function convertToShares(uint256 assets) external view returns (uint256);
function convertToAssets(uint256 shares) external view returns (uint256);

// Deposit
function deposit(uint256 assets, address receiver) external returns (uint256);
function mint(uint256 shares, address receiver) external returns (uint256);
function maxDeposit(address owner) external view returns (uint256);
function previewDeposit(uint256 assets) external view returns (uint256);

// Withdraw
function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
function maxWithdraw(address owner) external view returns (uint256);
function previewWithdraw(uint256 assets) external view returns (uint256);

// State
function asset() external view returns (address);
function totalAssets() external view returns (uint256);

// Events
event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
```

#### Integra Use Cases

**Primary Use Cases:**
1. **Private Equity Funds**
   - Limited partners deposit capital
   - Receive proportional fund shares
   - Shares appreciate with fund performance
   - Redemption based on NAV calculations

2. **Real Estate Investment Trusts (REITs)**
   - Pooled real estate ownership
   - Rental income auto-compounds into share value
   - Pro-rata distribution of sale proceeds
   - Quarterly redemption windows

3. **Revenue Sharing Agreements**
   - Multiple investors in profit pools
   - Business deposits revenue
   - Shares represent claim on accumulated revenue
   - Investors redeem based on current vault value

4. **Tokenized Bonds/Notes**
   - Principal + interest accumulation
   - Convertible note conversions
   - Maturity-based redemptions
   - Coupon payment reinvestment

5. **Trust Fund Management**
   - Beneficiaries earn yield on principal
   - Trustee manages underlying assets
   - Time-based redemption schedules
   - Estate distribution mechanisms

6. **Yield-Bearing Document Pools**
   - Invoice factoring pools
   - Royalty income aggregation
   - Patent licensing revenue pools
   - Collective IP monetization

#### Workflow Design

**Anonymous Reservation Flow:**
```
1. Fund manager creates vault document
   - Underlying asset: USDC, ETH, etc.
   - Total fund size: 1,000,000 shares reserved
   - Encrypted label: "Series A Preferred Fund - Q4 2025"

2. Investors verify identity off-chain
   - Accredited investor verification
   - KYC/AML compliance
   - Investment agreement signatures

3. Manager issues capability attestations
   - Attestation grants CAPABILITY_CLAIM_TOKEN
   - Attestation includes investment amount in tokenId field

4. Investors claim shares
   - Transfer underlying assets to vault
   - Receive proportional vault shares
   - Shares auto-delegate for voting/governance

5. Yield accumulation
   - totalAssets() increases as vault earns yield
   - Share value appreciates automatically
   - No manual distribution needed

6. Redemption
   - Investors call redeem(shares)
   - Receive proportional assets from vault
   - Shares burned, assets transferred

7. Trust credentials issued
   - When fund closes or reaches milestones
   - Proves successful investment completion
```

#### Architecture Design

**Key Features:**
- Inherits from `ERC4626Upgradeable` + `AttestationAccessControlV6`
- Implements `IDocumentResolver` + `IERC4626`
- Anonymous share reservations for investors
- Attestation-based claiming with asset deposit
- Encrypted labels for fund terms/investor classes

**State Variables:**
```solidity
struct VaultDocumentData {
    bytes32 integraHash;                // Document identifier
    address underlyingAsset;            // USDC, ETH, etc.
    uint256 totalSharesReserved;        // Reserved but not yet claimed
    uint256 totalSharesMinted;          // Currently outstanding
    mapping(address => uint256) reservations;  // Per-investor reservations
    mapping(address => bool) claimed;          // Track who has claimed
    bytes encryptedLabel;               // Fund description
    uint256 lockupPeriod;               // Minimum holding period (seconds)
    mapping(address => uint256) depositTimestamp;  // For lockup enforcement
}
```

**Special Considerations:**
- Override `deposit()` and `mint()` to integrate with attestation claiming
- Add lockup period enforcement (prevent early redemption)
- Implement redemption windows (quarterly, etc.)
- Support partial redemptions (claim some shares, keep others reserved)
- Integrate with trust graph for investor credentials
- Add emergency pause for vault operations
- Implement fee structures (management fees, performance fees)

**Rounding Protection:**
- Follow ERC-4626 spec: "favor the Vault itself during calculations"
- `convertToShares()` rounds DOWN
- `convertToAssets()` rounds DOWN
- Protects vault from donation attacks

---

### 3. RentalResolverV6 (ERC-4907)

#### Standard Overview

ERC-4907 extends ERC-721 to add a time-limited "user" role distinct from ownership. This enables NFT rentals where usage rights are separated from ownership rights.

**Key Interface Methods:**
```solidity
function setUser(uint256 tokenId, address user, uint64 expires) external;
function userOf(uint256 tokenId) external view returns (address);
function userExpires(uint256 tokenId) external view returns (uint256);

event UpdateUser(uint256 indexed tokenId, address indexed user, uint64 expires);
```

The owner retains transfer rights and can modify user assignments. Users gain temporary access but cannot transfer or reassign.

#### Integra Use Cases

**Primary Use Cases:**
1. **Residential Leases**
   - Landlord = NFT owner
   - Tenant = user (expires at lease end)
   - Lease terms in encrypted label
   - Automatic expiration, no manual eviction transaction
   - Security deposit via smart contract escrow

2. **Commercial Leases**
   - Property owner retains ownership NFT
   - Business tenant gets time-limited user rights
   - Sublease support (user can be changed by owner)
   - Lease extensions via `setUser()` update

3. **Equipment Rentals**
   - Construction equipment leasing
   - Medical device rentals
   - Vehicle leases (cars, boats, aircraft)
   - Tool libraries and maker spaces

4. **Software/IP Licenses**
   - Time-limited software licenses
   - Patent usage rights
   - Music streaming licenses
   - Content distribution rights

5. **Timeshare Properties**
   - Fractional vacation ownership
   - Rotating usage schedules
   - Reservation system integration
   - Seasonal allocations

6. **Event Access**
   - Conference attendance rights
   - Membership club access
   - Gym memberships
   - Coworking space access

7. **Subscription Services**
   - Netflix-style content access
   - SaaS platform subscriptions
   - Data feed access
   - API usage rights

8. **Gaming Assets**
   - In-game item rentals
   - Virtual land leasing
   - Character/avatar rentals
   - Guild equipment sharing

9. **Mortgage Structures**
   - Rent-to-own agreements
   - Installment purchases
   - Lease purchase options
   - Gradual ownership transfer

#### Workflow Design

**Anonymous Reservation Flow:**
```
1. Owner reserves rental NFT with encrypted label
   - Label: "123 Main St Apartment - 1BR/1BA - $2000/mo"
   - Owner address known (property owner)
   - User address unknown (future tenant)

2. Prospective tenant applies off-chain
   - Credit check, employment verification
   - Lease agreement negotiation
   - Security deposit payment

3. Owner issues capability attestation to approved tenant
   - Attestation grants CAPABILITY_CLAIM_TOKEN
   - Attestation includes lease expiration in data field

4. Tenant claims NFT
   - NFT minted to owner
   - User set to tenant with expiration timestamp
   - Owner retains ownership, tenant gets usage rights

5. Lease expiration
   - userOf() automatically returns address(0) after expiry
   - No manual eviction transaction needed
   - Owner can setUser() to new tenant or extend lease

6. Lease renewal
   - Owner calls setUser() with new expiration
   - No need to mint new token
   - Continuous lease history on-chain

7. Trust credentials issued
   - When lease completes successfully
   - Proves tenant/landlord relationship
   - Builds rental history reputation
```

**Advanced Scenarios:**

**Sublease Support:**
```
1. Tenant wants to sublease
2. Owner approves via attestation
3. Tenant becomes "sub-owner" (special role)
4. Sub-owner can setUser() to subtenant
5. Original owner retains ultimate control
```

**Rent-to-Own:**
```
1. Start as rental (user role)
2. Monthly payments tracked on-chain
3. After N payments, owner transfers ownership
4. User becomes owner, rental converts to ownership
```

#### Architecture Design

**Key Features:**
- Inherits from `ERC721Upgradeable` + `AttestationAccessControlV6`
- Implements `IDocumentResolver` + `IERC4907`
- Owner and user roles with distinct capabilities
- Automatic expiration (no manual revocation)
- Encrypted labels for lease terms

**State Variables:**
```solidity
struct RentalTokenData {
    bytes32 integraHash;        // Document identifier
    address owner;              // Property owner (NFT holder)
    address user;               // Current tenant/user
    uint64 expires;             // Lease expiration timestamp
    bool minted;                // Prevents double minting
    bytes encryptedLabel;       // Lease terms
    uint256 monthlyPayment;     // Rent amount (optional)
    uint256 securityDeposit;    // Escrowed deposit (optional)
    uint256 lastPayment;        // Last rent payment timestamp
}

// Payment tracking for rent-to-own
mapping(bytes32 => mapping(address => uint256)) public paymentsMade;
mapping(bytes32 => uint256) public paymentsRequired;  // For rent-to-own conversion
```

**Special Considerations:**
- Override `ownerOf()` to return property owner
- Implement `userOf()` with expiration checking
- Add payment tracking for rent collection
- Implement security deposit escrow
- Support lease extensions without new mints
- Add emergency eviction (GOVERNOR_ROLE only)
- Integrate with trust graph for rental history

**Access Control:**
- `setUser()` callable by:
  - Owner (direct control)
  - EXECUTOR_ROLE with owner's attestation (Integra platform)
- Transfer restrictions:
  - Owner can transfer ownership NFT
  - User role automatically cleared on transfer
  - New owner can set new user

---

### 4. RoyaltyResolverV6 (ERC-2981)

#### Standard Overview

ERC-2981 establishes a standardized mechanism for NFT creators to receive royalty payments on secondary sales. It's a query interface that marketplaces can use to determine royalty obligations.

**Key Interface Method:**
```solidity
function royaltyInfo(uint256 _tokenId, uint256 _salePrice)
    external view returns (address receiver, uint256 royaltyAmount);
```

The standard mandates percentage-based calculations (constant regardless of sale price) and supports EIP-165 interface detection.

#### Integra Use Cases

**Primary Use Cases:**
1. **Intellectual Property Licensing**
   - Patent licenses with ongoing royalties
   - Software licensing with usage fees
   - Brand licensing agreements
   - Franchise rights with revenue sharing

2. **Creative Works**
   - Digital art with artist royalties
   - Music composition rights
   - Book publishing rights
   - Photography licensing

3. **Revenue Rights Documents**
   - Product royalty agreements
   - Invention rights
   - Film/TV residuals
   - Streaming revenue shares

4. **Real Estate Appreciation Sharing**
   - Original developer gets % of resales
   - Equity sharing agreements
   - Property flip profit sharing
   - Community land trusts

5. **Business Sale Earnouts**
   - Seller receives % of future business sales
   - M&A earnout agreements
   - Contingent consideration tracking
   - Performance-based payments

6. **Securitized Assets**
   - Asset-backed securities with servicing fees
   - Loan origination with servicing rights
   - Mortgage servicing rights
   - Debt instrument secondary market fees

#### Workflow Design

**Anonymous Reservation Flow:**
```
1. Creator reserves royalty-enabled NFT
   - Royalty percentage: 10% (stored in contract)
   - Royalty recipient: Creator's address
   - Encrypted label: "Patent US-123456 - Widget Technology"

2. Initial buyer claims NFT
   - Attestation-based claiming (as usual)
   - Pays initial purchase price to creator
   - No royalty on primary sale

3. First resale (buyer → buyer2)
   - Marketplace queries royaltyInfo(tokenId, salePrice)
   - Contract returns (creatorAddress, salePrice * 10%)
   - Marketplace sends 10% to creator, 90% to seller

4. Subsequent resales
   - Royalty continues on every transfer
   - Creator receives ongoing passive income
   - Tracked via trust graph for revenue reporting

5. Trust credentials
   - Creator credential: Proves royalty earning history
   - Buyer credentials: Proves ownership transfers
```

**Advanced Scenarios:**

**Variable Royalties:**
```
1. Royalty percentage varies by transfer count
   - First 5 resales: 10%
   - Resales 6-10: 5%
   - Resales 11+: 2.5%
2. Encourages long-term holding
3. Reduces friction on mature assets
```

**Split Royalties:**
```
1. Multiple royalty recipients
   - Original creator: 6%
   - Platform fee: 2%
   - Collaborator: 2%
2. royaltyInfo() returns primary recipient
3. Recipient contract splits payments internally
```

**Royalty Buyouts:**
```
1. Buyer pays 10x royalty value upfront
2. Future royalties disabled for that token
3. Creator gets lump sum, buyer gets royalty-free asset
```

#### Architecture Design

**Key Features:**
- Inherits from `ERC721Upgradeable` + `AttestationAccessControlV6`
- Implements `IDocumentResolver` + `IERC2981`
- Configurable royalty percentages per document
- Multiple royalty recipient support (via splitter contract)
- Encrypted labels for royalty terms

**State Variables:**
```solidity
struct RoyaltyTokenData {
    bytes32 integraHash;            // Document identifier
    address owner;                  // Current owner
    bool minted;                    // Prevents double minting
    bytes encryptedLabel;           // Asset description

    // Royalty configuration
    address royaltyRecipient;       // Who receives royalties
    uint96 royaltyPercentage;       // Basis points (10000 = 100%)
    uint256 royaltyCapAmount;       // Optional cap (0 = no cap)

    // Transfer tracking
    uint256 transferCount;          // Number of times transferred
    uint256 totalRoyaltiesPaid;     // Cumulative royalties (off-chain tracking)

    // Variable royalty tiers
    RoyaltyTier[] royaltyTiers;     // Optional tiered royalties
}

struct RoyaltyTier {
    uint256 maxTransfers;           // Transfer count threshold
    uint96 royaltyPercentage;       // Royalty % for this tier
}
```

**Special Considerations:**
- Implement `royaltyInfo()` with tier logic
- Support fixed-cap royalties (max $X regardless of price)
- Add royalty buyout mechanism
- Track royalty payments for reporting (off-chain indexer)
- Support royalty recipient updates (in case of address changes)
- Integrate with trust graph for revenue credentials
- Add marketplace whitelist (optional enforcement)

**Royalty Calculation:**
```solidity
function royaltyInfo(uint256 tokenId, uint256 salePrice)
    external view returns (address receiver, uint256 royaltyAmount)
{
    RoyaltyTokenData storage data = tokenData[tokenId];

    // Get applicable royalty percentage based on transfer count
    uint96 percentage = _getRoyaltyPercentage(tokenId, data.transferCount);

    // Calculate royalty amount
    royaltyAmount = (salePrice * percentage) / 10000;

    // Apply cap if configured
    if (data.royaltyCapAmount > 0 && royaltyAmount > data.royaltyCapAmount) {
        royaltyAmount = data.royaltyCapAmount;
    }

    return (data.royaltyRecipient, royaltyAmount);
}
```

**Enforcement Note:**
ERC-2981 is a **query interface only** - it does NOT enforce royalty payments on-chain. Enforcement requires:
1. Marketplace cooperation (voluntary compliance)
2. Transfer hooks that revert without royalty payment (gas-intensive)
3. Off-chain monitoring and blacklisting non-compliant marketplaces
4. Legal agreements requiring royalty payments

For Integra, enforcement strategy should be documented in the legal agreement layer, with on-chain tracking for audit purposes.

---

### 5. BadgeResolverV6 (ERC-4671)

#### Standard Overview

ERC-4671 defines non-tradable tokens (NTTs), also known as badges or soulbound tokens, designed for inherently personal possessions like credentials and achievements. Unlike traditional NFTs, these tokens are non-transferable and include a revocation mechanism.

**Key Interface Methods:**
```solidity
function balanceOf(address owner) external view returns (uint256);
function ownerOf(uint256 tokenId) external view returns (address);
function isValid(uint256 tokenId) external view returns (bool);
function hasValid(address owner) external view returns (bool);

// Optional extensions
function emittedCount() external view returns (uint256);
function holdersCount() external view returns (uint256);
function revoke(uint256 tokenId) external;

// Pull mechanism (optional)
function pull(address from, address to, uint256 tokenId, bytes calldata signature) external;
```

**Key Difference from ERC-5192:**
- ERC-4671 includes **revocation** - tokens can be marked invalid while preserving historical records
- No `transfer()` or `transferFrom()` functions at all (removed from interface entirely)
- `isValid()` check allows credentials to be invalidated without deletion
- Optional "pull" mechanism allows recipients to move tokens between their own addresses

#### Integra Use Cases

**Primary Use Cases:**
1. **Revocable Licenses**
   - Driver's licenses (can be suspended/revoked)
   - Medical licenses (revocable for malpractice)
   - Business licenses (revocable for violations)
   - Temporary permits (expire or revoke)

2. **Time-Limited Certifications**
   - Annual safety training certificates
   - Security clearances (revocable)
   - Food handler permits
   - Forklift operator certifications

3. **Membership Badges**
   - DAO membership (revocable for bad behavior)
   - Club memberships
   - Professional association memberships
   - Alumni badges

4. **Achievement Tracking**
   - Employee training completions
   - Course certifications
   - Compliance training badges
   - Performance milestones

5. **Event Attendance**
   - Conference attendance badges
   - Webinar completion certificates
   - Meetup participation
   - Workshop certifications

6. **Government Documents**
   - Marriage certificates (revocable via divorce)
   - Birth certificates (correctable)
   - Vital records
   - Immigration status (revocable)

7. **Product Authenticity**
   - Product certification badges
   - Warranty certificates (revocable if voided)
   - Authenticity proofs
   - Quality certifications

#### Workflow Design

**Anonymous Reservation & Issuance Flow:**
```
1. Issuer reserves badge with encrypted label
   - Label: "Food Handler Certificate - Valid Until 2026"
   - Address unknown at reservation time
   - Badge initially marked valid

2. Recipient verifies eligibility off-chain
   - Training completion verification
   - Exam passage
   - Background check

3. Issuer issues capability attestation
   - Attestation grants CAPABILITY_CLAIM_TOKEN
   - Attestation includes recipient address

4. Recipient claims badge
   - Badge minted to recipient
   - Marked as valid
   - Non-transferable by design

5. Badge lifecycle management
   - Issuer can revoke via revoke(tokenId)
   - Token remains in recipient's wallet
   - isValid() returns false after revocation
   - Historical record preserved on-chain

6. Optional pull mechanism
   - Recipient can move badge between their own addresses
   - Requires signature from receiving address
   - Useful for wallet migrations
```

**Revocation Scenario:**
```
1. License holder violates terms
2. Issuer calls revoke(tokenId)
3. isValid(tokenId) now returns false
4. Token still exists in wallet (historical record)
5. hasValid(address) returns false if no other valid badges
6. Third parties can check validity status
```

#### Architecture Design

**Key Features:**
- Inherits from `AttestationAccessControlV6`
- Implements `IDocumentResolver` + `IERC4671`
- NO transfer functions (non-tradable by design)
- Revocation mechanism with historical preservation
- Optional pull mechanism for wallet migration
- Encrypted labels for credential details

**State Variables:**
```solidity
struct BadgeData {
    bytes32 integraHash;        // Document identifier
    address owner;              // Badge holder
    bool minted;                // Prevents double minting
    bool valid;                 // Revocation status (true = valid)
    bytes encryptedLabel;       // Badge details
    uint256 issuanceDate;       // When badge was claimed
    uint256 expirationDate;     // Optional expiration (0 = no expiry)
    uint256 revocationDate;     // When revoked (0 = not revoked)
}

// Badge tracking
mapping(uint256 => BadgeData) private badgeData;
mapping(address => uint256[]) private holderBadges;  // All badges per holder
mapping(address => uint256) private holderValidCount;  // Valid badge count
uint256 private _nextTokenId;
uint256 private _totalEmitted;
```

**Special Considerations:**
- NO `transfer()`, `transferFrom()`, or `approve()` functions
- Implement `revoke()` with ISSUER_ROLE or GOVERNOR_ROLE permission
- Add `pull()` for self-custody transfers (optional)
- Override `balanceOf()` to count both valid and invalid badges
- Implement `hasValid()` for quick validity checks
- Add automatic expiration checking (time-based invalidation)
- Integrate with trust graph for credential verification
- Support batch operations (mint/revoke multiple badges)

**Pull Mechanism (Optional):**
```solidity
function pull(
    address from,
    address to,
    uint256 tokenId,
    bytes calldata signature
) external {
    require(msg.sender == from || msg.sender == to, "Unauthorized");
    require(badgeData[tokenId].owner == from, "Not owner");

    // Verify signature from 'to' address authorizing pull
    bytes32 hash = keccak256(abi.encodePacked(from, to, tokenId));
    require(_verifySignature(hash, signature, to), "Invalid signature");

    // Transfer badge
    badgeData[tokenId].owner = to;
    _updateHolderBadges(from, to, tokenId);

    emit Transfer(from, to, tokenId);  // For tracking purposes
}
```

---

### 6. SecurityTokenResolverV6 (ERC-1400)

#### Standard Overview

ERC-1400 is a comprehensive library of standards for regulated security tokens on Ethereum. It combines multiple component standards (ERC-1410, ERC-1594, ERC-1643, ERC-1644) to enable compliant tokenization of financial securities.

**Component Standards:**
- **ERC-1410**: Partially fungible tokens with partition management
- **ERC-1594**: Transfer restriction checking with error signaling
- **ERC-1643**: Document/legend management
- **ERC-1644**: Controller operations (forced transfers)

**Key Interface Methods:**
```solidity
// Partition Management (ERC-1410)
function balanceOfByPartition(bytes32 partition, address tokenHolder) external view returns (uint256);
function partitionsOf(address tokenHolder) external view returns (bytes32[] memory);
function transferByPartition(bytes32 partition, address to, uint256 value, bytes calldata data) external returns (bytes32);
function operatorTransferByPartition(bytes32 partition, address from, address to, uint256 value, bytes data, bytes operatorData) external returns (bytes32);

// Transfer Validation (ERC-1594)
function canTransfer(address to, uint256 value, bytes calldata data) external view returns (bool, byte, bytes32);
function canTransferByPartition(address from, address to, bytes32 partition, uint256 value, bytes calldata data) external view returns (byte, bytes32, bytes32);

// Issuance & Redemption
function issue(address tokenHolder, uint256 value, bytes calldata data) external;
function issueByPartition(bytes32 partition, address tokenHolder, uint256 value, bytes calldata data) external;
function redeem(uint256 value, bytes calldata data) external;
function redeemByPartition(bytes32 partition, uint256 value, bytes calldata data) external;
function operatorRedeemByPartition(bytes32 partition, address tokenHolder, uint256 value, bytes operatorData) external;

// Controller Operations (ERC-1644)
function isControllable() external view returns (bool);
function controllerTransfer(address from, address to, uint256 value, bytes calldata data, bytes calldata operatorData) external;
function controllerRedeem(address tokenHolder, uint256 value, bytes calldata data, bytes calldata operatorData) external;

// Document Management (ERC-1643)
function getDocument(bytes32 name) external view returns (string memory, bytes32, uint256);
function setDocument(bytes32 name, string calldata uri, bytes32 documentHash) external;
function getAllDocuments() external view returns (bytes32[] memory);
```

**Partition System:**
Partitions allow tokens to exist in different states simultaneously:
- **"issued"** partition: Default holdings
- **"locked"** partition: Vesting/lockup restrictions
- **"reserved"** partition: Reserved for future issuance
- **Custom partitions**: Asset classes, voting rights, etc.

#### Integra Use Cases

**Primary Use Cases:**
1. **Private Securities Offerings**
   - Reg D offerings (accredited investors only)
   - Reg S offerings (offshore investors)
   - Reg A+ offerings (broader access)
   - Partition per investor class (accredited, institutional, retail)

2. **Equity Token Issuance**
   - Common stock with transfer restrictions
   - Preferred stock with different rights
   - Stock options (vesting partitions)
   - Restricted Stock Units (RSUs)
   - Employee stock ownership plans (ESOPs)

3. **Debt Securities**
   - Corporate bonds with partitions per series
   - Convertible notes (different conversion terms)
   - Promissory notes with transfer restrictions
   - Asset-backed securities (different tranches)

4. **Fund Tokens**
   - Private equity fund shares
   - Hedge fund interests
   - Venture capital fund tokens
   - Real estate fund tokens
   - Each fund class as a partition

5. **Regulatory Compliance**
   - KYC/AML whitelisting
   - Accredited investor verification
   - Transfer limits (max holders)
   - Lock-up periods (vesting schedules)
   - Jurisdiction restrictions (US vs non-US)

6. **Corporate Actions**
   - Stock splits (partition adjustments)
   - Dividends (partition-based distribution)
   - Rights offerings (new partitions)
   - Mergers/acquisitions (forced transfers)

7. **Legal/Court Orders**
   - Forced transfers via controller
   - Asset freezes (locked partitions)
   - Garnishments
   - Bankruptcy proceedings

#### Workflow Design

**Multi-Partition Security Issuance:**
```
1. Security issuer creates token contract
   - Name: "Acme Corp Series A Preferred"
   - Symbol: "ACME-A"
   - Controller: Issuer or transfer agent
   - Initial partitions: "locked", "unlocked"

2. Document management
   - Attach offering memorandum (ERC-1643)
   - Attach subscription agreement
   - Attach regulatory disclosures
   - All documents hashed and referenced on-chain

3. Investor onboarding (off-chain)
   - KYC/AML verification
   - Accredited investor status check
   - Subscription agreement signing
   - Issuer approves via attestation

4. Token reservation by partition
   - Investor A: 10,000 tokens → "locked" partition (1-year vesting)
   - Investor B: 5,000 tokens → "unlocked" partition (immediate)
   - Reserved anonymously (attestation-based claiming)

5. Investors claim tokens
   - Claim with capability attestation
   - Tokens minted to specific partition
   - Transfer restrictions enforced automatically

6. Vesting & partition transfers
   - After 1 year: issuer moves tokens from "locked" → "unlocked"
   - operatorTransferByPartition() by controller
   - Investor now has full transfer rights

7. Secondary transfers (with restrictions)
   - Buyer calls canTransfer() to pre-check eligibility
   - If compliant, transferByPartition() executes
   - If non-compliant, returns reason code (e.g., 0x52 = not whitelisted)

8. Controller operations (regulatory compliance)
   - Court order: controllerTransfer() forces transfer
   - Asset freeze: move tokens to "frozen" partition
   - Share buyback: controllerRedeem() burns tokens
```

**Advanced Scenarios:**

**Multi-Class Stock Structure:**
```
Partitions:
- "common-voting": Common stock with voting rights
- "common-non-voting": Common stock without votes
- "preferred-series-a": Series A preferred (liquidation preference)
- "preferred-series-b": Series B preferred (different terms)

Each partition has different:
- Transfer restrictions
- Voting power
- Dividend rights
- Liquidation preferences
```

**Vesting Schedule Implementation:**
```
1. Issue 48,000 tokens to "locked-monthly" partition
2. Each month: move 1,000 tokens to "unlocked" partition
3. Automated via off-chain service calling operatorTransferByPartition()
4. Tracks vesting progress transparently on-chain
```

**Jurisdiction-Based Restrictions:**
```
Partitions:
- "us-accredited": US accredited investors only
- "international": Non-US investors
- "us-retail": US Reg A+ retail investors

canTransfer() checks:
- Recipient whitelisted for destination partition
- Total holder count doesn't exceed limits
- Transfer amount doesn't violate concentration limits
```

#### Architecture Design

**Key Features:**
- Inherits from `AttestationAccessControlV6`
- Implements `IDocumentResolver` + `IERC1400` + component interfaces
- Partition-based token organization
- Transfer restrictions with reason codes
- Document management integration
- Controller operations for compliance
- Anonymous reservations per partition
- Encrypted labels per partition

**State Variables:**
```solidity
struct SecurityTokenData {
    bytes32 integraHash;                // Document identifier
    bool isControllable;                // Allow controller operations
    address controller;                 // Controller address (can force transfers)

    // Partition management
    mapping(bytes32 => uint256) totalSupplyByPartition;
    mapping(address => mapping(bytes32 => uint256)) balancesByPartition;
    mapping(address => bytes32[]) partitionsByHolder;

    // Transfer restrictions
    mapping(address => bool) whitelist;              // KYC'd addresses
    mapping(address => bool) accreditedInvestors;    // Accredited status
    mapping(address => bytes32) jurisdiction;        // US, UK, etc.
    uint256 maxHolders;                              // Regulatory limit
    uint256 currentHolders;                          // Current count

    // Partition metadata
    mapping(bytes32 => PartitionMetadata) partitionData;

    // Document management (ERC-1643)
    mapping(bytes32 => Document) documents;
    bytes32[] documentNames;
}

struct PartitionMetadata {
    bytes encryptedLabel;           // Partition description
    bool transferable;              // Can tokens be transferred
    uint256 totalReserved;          // Reserved tokens
    uint256 totalMinted;            // Issued tokens
    mapping(address => uint256) reservations;
    bool requiresWhitelist;         // Enforce whitelist
    bool requiresAccredited;        // Require accredited investor
}

struct Document {
    string uri;                     // IPFS or HTTPS URI
    bytes32 documentHash;           // Content hash verification
    uint256 timestamp;              // Last update time
}
```

**Special Considerations:**
- Implement comprehensive transfer validation (canTransfer)
- Use standardized reason codes for rejection (0x50-0x5F range)
- Add partition controller roles (per-partition operators)
- Implement automatic partition transitions (vesting)
- Support batch issuance/redemption (gas optimization)
- Add snapshot mechanism for dividends/distributions
- Integrate document hashing (ERC-1643)
- Implement emergency pause per partition
- Add holder limits enforcement
- Support off-chain data injection for compliance checks
- Integrate with trust graph for investor credentials

**Transfer Validation Logic:**
```solidity
function canTransferByPartition(
    address from,
    address to,
    bytes32 partition,
    uint256 value,
    bytes calldata data
) external view returns (byte, bytes32, bytes32) {
    PartitionMetadata storage meta = securityTokenData[integraHash].partitionData[partition];

    // Check 1: Partition must be transferable
    if (!meta.transferable) {
        return (0x50, bytes32(0), partition);  // Transfer restricted
    }

    // Check 2: Sender must have sufficient balance
    if (balancesByPartition[from][partition] < value) {
        return (0x52, bytes32(0), partition);  // Insufficient balance
    }

    // Check 3: Recipient must be whitelisted
    if (meta.requiresWhitelist && !whitelist[to]) {
        return (0x57, bytes32(0), partition);  // Invalid receiver
    }

    // Check 4: Recipient must be accredited investor
    if (meta.requiresAccredited && !accreditedInvestors[to]) {
        return (0x58, bytes32(0), partition);  // Invalid receiver type
    }

    // Check 5: Holder limit not exceeded
    if (balancesByPartition[to][partition] == 0 && currentHolders >= maxHolders) {
        return (0x53, bytes32(0), partition);  // Receiver not eligible
    }

    // All checks passed
    return (0x51, bytes32(0), partition);  // Transfer valid
}
```

**Reason Codes (ERC-1594):**
- `0x50`: Transfer restricted
- `0x51`: Transfer valid
- `0x52`: Insufficient balance
- `0x53`: Receiver not eligible (holder limit)
- `0x54`: Sender locked (lockup period)
- `0x55`: Tokens locked (vesting)
- `0x56`: Invalid sender
- `0x57`: Invalid receiver (not whitelisted)
- `0x58`: Invalid receiver type (not accredited)

---

## Implementation Timeline

### Phase 1: Design & Specification (Week 1-2)
- [ ] Finalize architectural designs for all 6 resolvers
- [ ] Define state variables and storage layouts
- [ ] Document integration points with existing V6 contracts
- [ ] Create Solidity interfaces for each resolver
- [ ] Design trust graph credential schemas

### Phase 2: Core Implementation (Week 3-10)

**Week 3: SoulboundResolverV6**
- [ ] Implement ERC-5192 interface
- [ ] Add locking mechanism and transfer overrides
- [ ] Integrate attestation-based claiming
- [ ] Add expiration tracking for time-limited credentials
- [ ] Implement trust graph integration

**Week 4: BadgeResolverV6**
- [ ] Implement ERC-4671 interface
- [ ] Add non-transferable badge logic (no transfer functions)
- [ ] Implement revocation mechanism (isValid tracking)
- [ ] Add optional pull mechanism for wallet migration
- [ ] Integrate attestation-based claiming
- [ ] Implement trust graph integration

**Week 5: VaultResolverV6**
- [ ] Implement ERC-4626 interface
- [ ] Add deposit/withdraw/redeem logic
- [ ] Integrate attestation-based share claiming
- [ ] Implement lockup period enforcement
- [ ] Add fee structures (management, performance)
- [ ] Integrate trust graph for investor credentials

**Week 6: RentalResolverV6**
- [ ] Implement ERC-4907 interface
- [ ] Add owner/user role separation
- [ ] Implement automatic expiration logic
- [ ] Add payment tracking for rent collection
- [ ] Implement security deposit escrow
- [ ] Add rent-to-own conversion logic
- [ ] Integrate trust graph for rental history

**Week 7: RoyaltyResolverV6**
- [ ] Implement ERC-2981 interface
- [ ] Add royalty calculation with tier support
- [ ] Implement royalty recipient management
- [ ] Add transfer counting for variable royalties
- [ ] Implement royalty buyout mechanism
- [ ] Integrate trust graph for revenue tracking

**Week 8-10: SecurityTokenResolverV6**
- [ ] Implement ERC-1400 base and component standards (ERC-1410, ERC-1594, ERC-1643, ERC-1644)
- [ ] Add partition management system
- [ ] Implement transfer validation with reason codes
- [ ] Add document management (ERC-1643)
- [ ] Implement controller operations (forced transfers, redemptions)
- [ ] Add whitelist/accreditation management
- [ ] Implement vesting and lockup logic
- [ ] Integrate attestation-based claiming per partition
- [ ] Integrate trust graph for security holder credentials

### Phase 3: Testing (Week 11-13)
- [ ] Unit tests for each resolver (100% coverage)
- [ ] Integration tests with AttestationAccessControlV6
- [ ] Integration tests with Layer 0/1/2 contracts
- [ ] Gas optimization analysis
- [ ] Security audit preparation

### Phase 4: Documentation & Deployment (Week 14-16)
- [ ] Technical documentation for each resolver
- [ ] Use case guides and examples
- [ ] Deployment scripts for all networks
- [ ] Registry updates for new resolver types
- [ ] Migration guides from V5 contracts (if applicable)

---

## Integration Architecture

### Layer 0 Integration: AttestationAccessControlV6

All resolvers inherit from `AttestationAccessControlV6` which provides:
- EAS integration for capability attestations
- Role-based access control (GOVERNOR, EXECUTOR, OPERATOR)
- Document issuer tracking
- Pausability for emergency response

```solidity
contract SoulboundResolverV6 is
    ERC721Upgradeable,
    AttestationAccessControlV6,
    IERC5192,
    IDocumentResolver
{
    // Implementation
}
```

### Layer 1 Integration: Registry

Each resolver must be registered in the Integra registry:

```solidity
// In IntegraRegistryV6
enum ResolverType {
    OWNERSHIP,         // ERC-721
    SHARES,            // ERC-20 Votes
    MULTIPARTY,        // ERC-1155
    SOULBOUND,         // ERC-5192 (new)
    BADGE,             // ERC-4671 (new)
    VAULT,             // ERC-4626 (new)
    RENTAL,            // ERC-4907 (new)
    ROYALTY,           // ERC-721 + ERC-2981 (new)
    SECURITY_TOKEN     // ERC-1400 (new)
}
```

### Layer 2 Integration: Executor

The `IntegraExecutorV6` contract orchestrates resolver interactions:

```solidity
// In IntegraExecutorV6
function reserveTokenAnonymous(
    ResolverType resolverType,
    bytes32 integraHash,
    uint256 tokenId,
    uint256 amount,
    bytes calldata encryptedLabel
) external {
    address resolver = registry.getResolver(resolverType);
    IDocumentResolver(resolver).reserveTokenAnonymous(
        msg.sender,
        integraHash,
        tokenId,
        amount,
        encryptedLabel
    );
}
```

### Trust Graph Integration

Each resolver issues trust credentials when document operations complete:

```solidity
function _handleTrustCredential(bytes32 integraHash, address party) internal {
    if (trustRegistry == address(0)) return;
    if (credentialsIssued[integraHash]) return;

    // Track party for credential issuance
    if (!_isPartyTracked(integraHash, party)) {
        documentParties[integraHash].push(party);
    }

    // Check if document complete (resolver-specific logic)
    if (_isDocumentComplete(integraHash)) {
        _issueCredentialsToAllParties(integraHash);
    }
}
```

---

## Testing Strategy

### Unit Tests

Each resolver requires comprehensive unit tests:

**SoulboundResolverV6:**
- ✓ Token locking on mint
- ✓ Transfer reverts when locked
- ✓ Emergency unlock by GOVERNOR
- ✓ Expiration checking for time-limited credentials
- ✓ Attestation-based claiming
- ✓ Trust credential issuance

**VaultResolverV6:**
- ✓ Deposit/mint functionality
- ✓ Withdraw/redeem functionality
- ✓ Share-to-asset conversion accuracy
- ✓ Lockup period enforcement
- ✓ Fee calculations (management, performance)
- ✓ Partial redemptions
- ✓ Attestation-based claiming with asset transfer

**RentalResolverV6:**
- ✓ Owner/user role separation
- ✓ Automatic expiration behavior
- ✓ setUser() permissions
- ✓ Transfer clears user role
- ✓ Payment tracking
- ✓ Security deposit escrow
- ✓ Rent-to-own conversion

**RoyaltyResolverV6:**
- ✓ royaltyInfo() calculations
- ✓ Tiered royalty percentages
- ✓ Royalty caps
- ✓ Transfer counting
- ✓ Royalty recipient updates
- ✓ Royalty buyout mechanism

**BadgeResolverV6:**
- ✓ Badge minting (non-transferable)
- ✓ Transfer functions revert (non-tradable)
- ✓ Revocation mechanism (isValid)
- ✓ Historical record preservation
- ✓ Pull mechanism for wallet migration
- ✓ Expiration checking
- ✓ Batch operations

**SecurityTokenResolverV6:**
- ✓ Partition balance tracking
- ✓ Transfer validation (canTransferByPartition)
- ✓ Reason code accuracy
- ✓ Operator transfers by partition
- ✓ Controller forced transfers
- ✓ Whitelist enforcement
- ✓ Accreditation requirements
- ✓ Holder limit enforcement
- ✓ Document management (ERC-1643)
- ✓ Issuance/redemption by partition
- ✓ Vesting schedule transitions

### Integration Tests

Cross-contract interaction tests:
- Executor → Resolver interactions
- Registry resolver lookups
- EAS attestation verification
- Trust credential issuance
- Multi-resolver document workflows

### Gas Optimization

Target gas costs for key operations:
- Reserve token: < 100k gas
- Claim token: < 150k gas
- Transfer: < 100k gas (if applicable)
- Query functions: < 30k gas

---

## Security Considerations

### Access Control

**Critical Functions:**
- `reserveToken()` / `reserveTokenAnonymous()` - EXECUTOR_ROLE only
- `cancelReservation()` - EXECUTOR_ROLE + issuer check
- `pause()` / `unpause()` - GOVERNOR_ROLE only
- `_authorizeUpgrade()` - GOVERNOR_ROLE only
- Emergency functions - GOVERNOR_ROLE only

### Reentrancy Protection

All state-changing functions must use `nonReentrant` modifier:
- Claiming functions (mint + transfer)
- Deposit/withdraw (VaultResolver)
- Payment functions (RentalResolver)

### Integer Overflow/Underflow

Use Solidity 0.8.24+ with built-in overflow checking.

### Rounding Attacks

**VaultResolverV6:**
- Follow ERC-4626 spec for rounding direction
- Favor vault over users in conversions
- Prevent donation attacks via rounding

### Front-Running

**VaultResolverV6:**
- Use slippage protection on deposits/withdrawals
- Consider private mempool for large deposits

**RoyaltyResolverV6:**
- Royalty percentages immutable after initial set
- Prevent royalty front-running on transfers

### Time Manipulation

**RentalResolverV6:**
- Expiration uses `block.timestamp`
- Miners can manipulate by ~15 seconds
- Use safe time windows (hours/days, not seconds)

**SoulboundResolverV6:**
- Similar time manipulation considerations for expiration

---

## Deployment Strategy

### Network Deployment Order

1. **Testnet Deployment** (Sepolia, Mumbai)
   - Deploy all 6 resolvers
   - Deploy test EAS schemas
   - Full integration testing
   - Gas profiling

2. **Mainnet Deployment** (Ethereum, Polygon, Optimism, etc.)
   - Deploy AttestationAccessControlV6 base (if not already)
   - Deploy each resolver with UUPS proxy
   - Register in IntegraRegistryV6
   - Update IntegraExecutorV6 to support new resolver types
   - Create EAS schemas for credentials

### Initialization Parameters

**SoulboundResolverV6:**
```solidity
initialize(
    name: "Integra Soulbound Credentials",
    symbol: "ISC",
    baseURI: "https://metadata.integra.network/soulbound/",
    governor: <GOVERNOR_ADDRESS>,
    eas: <EAS_ADDRESS>,
    accessCapabilitySchema: <SCHEMA_UID>,
    credentialSchema: <SCHEMA_UID>,
    trustRegistry: <TRUST_REGISTRY_ADDRESS>
)
```

**VaultResolverV6:**
```solidity
initialize(
    name: "Integra Vault Shares",
    symbol: "IVS",
    asset: <UNDERLYING_ASSET_ADDRESS>,  // USDC, ETH, etc.
    governor: <GOVERNOR_ADDRESS>,
    eas: <EAS_ADDRESS>,
    accessCapabilitySchema: <SCHEMA_UID>,
    credentialSchema: <SCHEMA_UID>,
    trustRegistry: <TRUST_REGISTRY_ADDRESS>
)
```

**RentalResolverV6:**
```solidity
initialize(
    name: "Integra Rental Agreements",
    symbol: "IRA",
    baseURI: "https://metadata.integra.network/rental/",
    governor: <GOVERNOR_ADDRESS>,
    eas: <EAS_ADDRESS>,
    accessCapabilitySchema: <SCHEMA_UID>,
    credentialSchema: <SCHEMA_UID>,
    trustRegistry: <TRUST_REGISTRY_ADDRESS>
)
```

**RoyaltyResolverV6:**
```solidity
initialize(
    name: "Integra Royalty Assets",
    symbol: "IRA",
    baseURI: "https://metadata.integra.network/royalty/",
    governor: <GOVERNOR_ADDRESS>,
    eas: <EAS_ADDRESS>,
    accessCapabilitySchema: <SCHEMA_UID>,
    credentialSchema: <SCHEMA_UID>,
    trustRegistry: <TRUST_REGISTRY_ADDRESS>
)
```

---

## Future Enhancements

### Post-V1 Features

1. **Cross-Chain Support**
   - Layer-zero integration for cross-chain resolvers
   - Multi-chain document synchronization
   - Cross-chain royalty payments

2. **Advanced Vault Features**
   - Multi-asset vaults (basket of tokens)
   - Automated rebalancing strategies
   - Yield optimization via DeFi integrations

3. **Rental Marketplace**
   - On-chain rental listings
   - Automated rent collection
   - Dispute resolution mechanisms

4. **Royalty Enforcement**
   - On-chain royalty escrow
   - Transfer hooks for mandatory payments
   - Blacklist non-compliant marketplaces

5. **Soulbound Credential Verification**
   - ZK proofs for credential privacy
   - Selective disclosure of attributes
   - Verifiable credential registry

---

## Appendix

### A. Token Standard Comparison Table

| Feature | ERC-5192 | ERC-4671 | ERC-4626 | ERC-4907 | ERC-2981 | ERC-1400 |
|---------|----------|----------|----------|----------|----------|----------|
| **Base Standard** | ERC-721 | Custom | ERC-20 | ERC-721 | ERC-721 | ERC-20 + Custom |
| **Transferability** | Non-transferable | Non-transferable | Transferable | Owner: Yes, User: No | Transferable | Restricted |
| **Fungibility** | Non-fungible | Non-fungible | Fungible | Non-fungible | Non-fungible | Partially Fungible |
| **Key Feature** | Locked tokens | Revocable badges | Yield-bearing shares | Time-limited user | Royalty payments | Partitions + Compliance |
| **Revocation** | No | Yes | N/A | No | No | Controller ops |
| **Use Case** | Credentials | Revocable licenses | Investment funds | Rentals | Creator royalties | Regulated securities |
| **Complexity** | Low | Medium | High | Medium | Low | Very High |
| **Gas Cost** | ~ERC-721 | ~ERC-721 | Higher (ERC-20) | ~ERC-721 | ~ERC-721 | Highest (partitions) |

### B. Gas Cost Estimates

**SoulboundResolverV6:**
- Reserve: ~80k gas
- Claim: ~130k gas (mint + lock)
- Query locked(): ~5k gas

**VaultResolverV6:**
- Reserve: ~100k gas
- Claim + Deposit: ~200k gas (claim + transfer + mint shares)
- Redeem: ~150k gas
- Query conversions: ~10k gas

**RentalResolverV6:**
- Reserve: ~90k gas
- Claim: ~140k gas (mint + set user)
- setUser(): ~30k gas
- Query userOf(): ~8k gas

**RoyaltyResolverV6:**
- Reserve: ~85k gas
- Claim: ~135k gas
- Transfer with royalty: ~100k gas + royalty transfer gas
- Query royaltyInfo(): ~10k gas

**BadgeResolverV6:**
- Reserve: ~75k gas
- Claim: ~125k gas (mint, non-transferable)
- Revoke: ~40k gas
- Query isValid(): ~5k gas
- Pull (wallet migration): ~50k gas

**SecurityTokenResolverV6:**
- Reserve by partition: ~150k gas (complex state)
- Claim by partition: ~220k gas (partition + compliance checks)
- Transfer by partition: ~180k gas (validation logic)
- Controller transfer: ~200k gas (forced transfer)
- Query canTransferByPartition(): ~50k gas (multiple checks)
- Issue by partition: ~150k gas
- Set document: ~80k gas

### C. EAS Schema Definitions

**Capability Attestation Schema** (used by all resolvers):
```
string: integraHash (document identifier)
string: capability (CLAIM_TOKEN, etc.)
uint256: tokenId (optional - for resolver-specific data)
uint256: amount (optional - for share amounts)
uint64: expiration (attestation expiry)
```

**Trust Credential Schema** (issued on completion):
```
bytes32: credentialHash (credential identifier)
bytes32: integraHash (document reference)
uint256: timestamp (issuance time)
string: credentialType (SOULBOUND_CREDENTIAL, INVESTMENT_COMPLETION, etc.)
```

### D. Interface Compatibility Matrix

All V6 resolvers implement:
- ✓ `IDocumentResolver` (Integra standard)
- ✓ `IERC165` (Interface detection)
- ✓ `IAccessControl` (Role-based access)
- ✓ `IERC1967` (UUPS upgradability)

Additional interfaces by resolver:
- **SoulboundResolverV6**: `IERC721`, `IERC721Metadata`, `IERC5192`
- **BadgeResolverV6**: `IERC4671`, `IERC4671Metadata`, `IERC4671Enumerable`
- **VaultResolverV6**: `IERC20`, `IERC20Metadata`, `IERC4626`, `IERC20Votes`
- **RentalResolverV6**: `IERC721`, `IERC721Metadata`, `IERC4907`
- **RoyaltyResolverV6**: `IERC721`, `IERC721Metadata`, `IERC2981`
- **SecurityTokenResolverV6**: `IERC20`, `IERC1400`, `IERC1410`, `IERC1594`, `IERC1643`, `IERC1644`

---

## Conclusion

These six additional resolvers significantly expand Integra's document tokenization capabilities, addressing specialized use cases across:
- **Credentials** (SoulboundResolverV6, BadgeResolverV6)
- **Investments** (VaultResolverV6)
- **Rentals** (RentalResolverV6)
- **Royalties** (RoyaltyResolverV6)
- **Regulated Securities** (SecurityTokenResolverV6)

Each resolver maintains the V6 architecture principles of anonymous reservations, attestation-based access control, and trust graph integration.

The implementation plan provides a clear path from design to deployment, with comprehensive testing and security considerations. Upon completion, Integra will offer a complete suite of **9 resolver contracts** covering the full spectrum of document tokenization needs:

**Existing (3):**
1. OwnershipResolverV6 (ERC-721)
2. SharesResolverV6 (ERC-20 Votes)
3. MultiPartyResolverV6 (ERC-1155)

**New (6):**
4. SoulboundResolverV6 (ERC-5192)
5. BadgeResolverV6 (ERC-4671)
6. VaultResolverV6 (ERC-4626)
7. RentalResolverV6 (ERC-4907)
8. RoyaltyResolverV6 (ERC-2981)
9. SecurityTokenResolverV6 (ERC-1400)

**Next Steps:**
1. Review and approve this implementation plan
2. Begin Phase 1 (Design & Specification)
3. Set up testing infrastructure
4. Assign implementation tasks to development team

---

**Document Version:** 3.1
**Last Updated:** 2025-11-04
**Authors:** Claude Code + Integra Development Team
**Status:** Draft - Awaiting Approval

**Changelog:**
- v3.1: Removed ERC-5114, replaced ERC-1400 with ERC-3643, added ERC-3525 (7 total new resolvers)
- v2.0: Added ERC-4671 (BadgeResolverV6) and ERC-1400 (SecurityTokenResolverV6)
- v1.0: Initial version with 4 resolvers (ERC-5192, ERC-4626, ERC-4907, ERC-2981)
