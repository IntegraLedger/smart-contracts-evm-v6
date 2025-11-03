# V6 Smart Contracts - Field Limits Analysis

**Purpose:** Analyze all text/data field limits across contracts for appropriateness

---

## 📊 **Current Limits Summary**

| Contract | Field | Current Limit | Purpose | Assessment |
|----------|-------|---------------|---------|------------|
| **IntegraDocumentRegistry** | encryptedData | 2,000 bytes | Encrypted contact URL | ✅ Optimal |
| **Layer 3 Resolvers** | encryptedLabel | 2,000 bytes | Encrypted role/party description | ✅ Optimal |
| **IntegraSignal** | encryptedPayload | 50,000 bytes | Full encrypted payment details | ⚠️ Review |
| **IntegraSignal** | reference | 200 bytes | Invoice #, description | ✅ Good |
| **IntegraSignal** | displayCurrency | 10 bytes | Currency code | ✅ Perfect |
| **IntegraMessage** | eventRef | 100 bytes | Event reference | ✅ Good |
| **IntegraMessage** | message | 1,000 bytes | Workflow message | ✅ Good |
| **IntegraVerifierRegistry** | circuitType | 100 bytes | Circuit name | ✅ Good |
| **IntegraVerifierRegistry** | version | 50 bytes | Version string | ✅ Good |

---

## 📋 **Detailed Analysis**

### 1. IntegraDocumentRegistry - encryptedData

**Updated:** 10,000 → **2,000 bytes** ✅

**Purpose:** Encrypted contact information (URLs, email, etc.)

**What Fits:**
- ✅ Encrypted URL (~500 bytes plaintext → ~800 bytes encrypted+encoded)
- ✅ Email + phone + URL (~300 bytes plaintext → ~500 bytes encrypted)
- ✅ Small JSON payload with contact methods
- ✅ IPFS hash for larger data (~60 bytes)

**Gas Cost:** ~$64 @ 20gwei/$2.5k ETH (vs $320 for 10KB)

**Recommendation:** ✅ **2,000 bytes is optimal**

---

### 2. Layer 3 Resolvers - encryptedLabel

**Updated:** 10,000 → **2,000 bytes** ✅

**Purpose:** Encrypted description of token/share/role

**Examples:**
- "Primary Owner" (encrypted)
- "10% Revenue Share - Series A Investor"
- "Buyer - Real Estate Transaction #12345"
- "Signatory - Employment Contract - VP Engineering"

**What Fits:**
- ✅ Role descriptions (~200 bytes plaintext → ~400 bytes encrypted)
- ✅ Party identification with metadata
- ✅ IPFS hash for detailed role documentation

**Gas Cost:** ~$64 per token reservation

**Recommendation:** ✅ **2,000 bytes is optimal**

---

### 3. IntegraSignal - encryptedPayload

**Current:** **50,000 bytes (50KB)** ⚠️

**Purpose:** Encrypted payment details (amount, account info, instructions)

**Analysis:**

**What's Actually Needed:**
```json
{
  "amount": "1000.00",
  "currency": "USD",
  "account_type": "wire",
  "routing": "123456789",
  "account": "987654321",
  "swift": "ABCDUS33",
  "reference": "Invoice #12345",
  "notes": "Payment for services rendered..."
}
```
**Plaintext:** ~400-800 bytes
**Encrypted (ECIES):** ~500-1,000 bytes
**Base64 encoded:** ~700-1,400 bytes

**Including:**
- Bank account details
- Wire instructions
- Crypto wallet addresses
- Payment platform credentials
- Detailed notes

**Realistic Maximum:** ~3,000-5,000 bytes for complex international wire with extensive notes

**Current 50KB Allows:**
- ✅ Any realistic payment payload
- ⚠️ But enables massive gas attacks (50KB × ~100 gas/byte = **5M gas = $250**)

**Gas Cost Comparison:**

| Size | Gas Cost | Attack Cost |
|------|----------|-------------|
| 5KB (recommended) | ~$160 | $160 spam |
| 10KB | ~$320 | $320 spam |
| 50KB (current) | ~$1,600 | $1,600 spam |

**Recommendation:** ⚠️ **Reduce to 5,000 bytes (5KB)**

**Rationale:**
- Sufficient for complex international payment instructions
- 10x cheaper than current limit
- Better spam protection ($160 vs $1,600)
- Still generous buffer for edge cases

**If need more:** Use IPFS and store hash (encrypted document on IPFS, hash in payload field)

---

### 4. IntegraSignal - reference (Invoice #)

**Current:** **200 bytes** ✅

**Purpose:** Invoice number, purchase order, description

**Examples:**
- "INV-2024-12345"
- "PO-ACME-2024-Q4-00123"
- "Payment for consulting services - October 2024"

**Analysis:**
- Typical invoice #: 20-50 bytes
- Long descriptions: 100-150 bytes
- **200 bytes is generous**

**Recommendation:** ✅ **Keep at 200 bytes** (perfect for purpose)

---

### 5. IntegraSignal - displayCurrency

**Current:** **10 bytes** ✅

**Purpose:** Currency code for display

**Examples:**
- "USD" (3 bytes)
- "EUR" (3 bytes)
- "BTC" (3 bytes)
- "USDC" (4 bytes)
- "ETH" (3 bytes)

**Analysis:**
- ISO 4217 currency codes: 3 bytes
- Crypto tickers: 3-5 bytes
- **10 bytes is perfect**

**Recommendation:** ✅ **Keep at 10 bytes** (optimal)

---

### 6. IntegraMessage - eventRef

**Current:** **100 bytes** ✅

**Purpose:** Event reference identifier

**Examples:**
- "WORKFLOW_APPROVED"
- "DOCUMENT_SIGNED_BY_ALL_PARTIES"
- "MILESTONE_COMPLETED_PHASE_3"

**Analysis:**
- Event codes: 20-50 bytes typical
- **100 bytes is appropriate**

**Recommendation:** ✅ **Keep at 100 bytes**

---

### 7. IntegraMessage - message

**Current:** **1,000 bytes** ✅

**Purpose:** Workflow message content

**Examples:**
- "All parties have signed the agreement. Proceeding to execution phase."
- "Payment milestone #3 completed. Next review scheduled for 2024-12-15."

**Analysis:**
- Typical message: 200-500 bytes
- **1,000 bytes allows detailed messages**
- Gas cost: ~$32 @ 1KB

**Recommendation:** ✅ **Keep at 1,000 bytes** (good for detailed workflow messages)

---

### 8. IntegraVerifierRegistry - circuitType

**Current:** **100 bytes** ✅

**Purpose:** ZK circuit type identifier

**Examples:**
- "BasicAccessV1Poseidon"
- "DocumentOwnershipProof"
- "MultiPartySignatureVerifier"

**Analysis:**
- Circuit names: 20-60 bytes typical
- **100 bytes is appropriate**

**Recommendation:** ✅ **Keep at 100 bytes**

---

### 9. IntegraVerifierRegistry - version

**Current:** **50 bytes** ✅

**Purpose:** Verifier version string

**Examples:**
- "v1"
- "v2.1.0"
- "1.0.0-beta.2"

**Analysis:**
- Semantic versioning: 5-20 bytes
- **50 bytes is generous and appropriate**

**Recommendation:** ✅ **Keep at 50 bytes**

---

## 🎯 **Summary of Recommendations**

| Field | Current | Recommended | Change | Reason |
|-------|---------|-------------|--------|--------|
| **IntegraDocumentRegistry.encryptedData** | 10,000 | **2,000** | ✅ Updated | Gas optimization |
| **Resolvers.encryptedLabel** | 10,000 | **2,000** | ✅ Updated | Gas optimization |
| **IntegraSignal.encryptedPayload** | 50,000 | **5,000** | ⚠️ Needs update | Attack protection |
| **IntegraSignal.reference** | 200 | **200** | ✅ Perfect | Keep as-is |
| **IntegraSignal.displayCurrency** | 10 | **10** | ✅ Perfect | Keep as-is |
| **IntegraMessage.eventRef** | 100 | **100** | ✅ Good | Keep as-is |
| **IntegraMessage.message** | 1,000 | **1,000** | ✅ Good | Keep as-is |
| **IntegraVerifierRegistry.circuitType** | 100 | **100** | ✅ Good | Keep as-is |
| **IntegraVerifierRegistry.version** | 50 | **50** | ✅ Good | Keep as-is |

---

## 🔴 **Action Required:**

### **Reduce IntegraSignal.MAX_ENCRYPTED_PAYLOAD_LENGTH**

**From:** 50,000 bytes (50KB)
**To:** 5,000 bytes (5KB)

**Impact:**
```
Gas Savings per Payment Request:
- Current (50KB): ~$1,600 @ 20gwei/$2.5k ETH
- Recommended (5KB): ~$160
- Savings: $1,440 per request (90% reduction)

Annual Savings (10k payment requests):
- Current cost: $16,000,000
- New cost: $1,600,000
- Savings: $14,400,000 (90%)

Spam Attack Protection:
- Current: $1,600 per spam (weak deterrent at scale)
- New: $160 per spam (better protection)
```

**What Still Fits in 5KB:**
- ✅ Complete wire transfer instructions
- ✅ Multiple payment methods
- ✅ Extensive notes and references
- ✅ International payment details
- ✅ Crypto wallet addresses + memo fields

**What Doesn't Fit:**
- ❌ Entire legal documents
- ❌ Multiple page contracts
- ❌ Large attachments

**For Large Payloads:** Use IPFS and include hash

---

## 💾 **Gas Cost Impact Summary**

### **Before Optimization (All 10KB limits):**
```
Document registration: ~$320 in encrypted data
Token reservation: ~$320 in encrypted label
Payment request: ~$1,600 in encrypted payload
Total per full workflow: ~$2,240
```

### **After Optimization (2KB/5KB limits):**
```
Document registration: ~$64 in encrypted data (↓80%)
Token reservation: ~$64 in encrypted label (↓80%)
Payment request: ~$160 in encrypted payload (↓90%)
Total per full workflow: ~$288 (↓87%)
```

**Annual Savings (10k full workflows):**
- Before: $22,400,000
- After: $2,880,000
- **Savings: $19,520,000 (87%)**

---

## ✅ **Recommended Changes**

```solidity
// IntegraDocumentRegistry.sol
uint256 public constant MAX_ENCRYPTED_DATA_LENGTH = 2000;  // ✅ Updated

// All Layer 3 Resolvers
uint256 public constant MAX_ENCRYPTED_LABEL_LENGTH = 2000;  // ✅ Updated

// IntegraSignal.sol - NEEDS UPDATE
uint256 public constant MAX_ENCRYPTED_PAYLOAD_LENGTH = 5000;  // ⚠️ Currently 50000

// All others - Keep as-is
uint256 public constant MAX_REFERENCE_LENGTH = 200;  // ✅ Good
uint256 public constant MAX_DISPLAY_CURRENCY_LENGTH = 10;  // ✅ Perfect
uint256 public constant MAX_EVENT_REF_LENGTH = 100;  // ✅ Good
uint256 public constant MAX_MESSAGE_LENGTH = 1000;  // ✅ Good
uint256 public constant MAX_CIRCUIT_TYPE_LENGTH = 100;  // ✅ Good
uint256 public constant MAX_VERSION_LENGTH = 50;  // ✅ Good
```

---

**Would you like me to update IntegraSignal.MAX_ENCRYPTED_PAYLOAD_LENGTH from 50KB to 5KB?**
