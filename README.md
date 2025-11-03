# @integraledger/smart-contracts-evm-v6

Integra V6 Smart Contracts - Enhanced document identity and tokenization system with attestation-based access control.

## 🎯 Overview

V6 smart contracts provide a complete decentralized document management and tokenization platform with:
- **Privacy-preserving** document identity
- **Attestation-based** access control (via EAS)
- **Flexible tokenization** strategies (ERC-721, ERC-20 Votes, ERC-1155)
- **Emergency controls** (pausable)
- **Gas-optimized** field limits
- **Upgradeable** (UUPS pattern)

## 📦 Installation

```bash
npm install @integraledger/smart-contracts-evm-v6
```

## 🚀 Deployed Contracts (Polygon Mainnet)

### Core Contracts

| Contract | Address | Purpose |
|----------|---------|---------|
| **IntegraDocumentRegistryV6** | `0x8609E5627933665D4576aAE992b13465fedecBde` | Document identity registry |
| **IntegraVerifierRegistryV6** | `0x4A6EBd1f4Ac78A58632f7009f43AB087810335CC` | ZK verifier management |

### Tokenization Resolvers (Layer 3)

| Contract | Address | Token Standard |
|----------|---------|----------------|
| **OwnershipResolverV6** | `0x98ec167546ae0cFEDB0955bcD93AC473761ce7FF` | ERC-721 (Single ownership) |
| **SharesResolverV6** | `0xAd0A3e01FA7E7081e5718E2aE5f722eF2849578D` | ERC-20 Votes (Fractional) |
| **MultiPartyResolverV6** | `0x5D83e8b6caebf6d3eb5ad222592708b7215b36D8` | ERC-1155 (Multi-party) |

### Communication (Layer 4)

| Contract | Address | Purpose |
|----------|---------|---------|
| **IntegraMessageV6** | `0x0247F6AF7D27988EAfcDA0540B20e79375875D0a` | Workflow events |
| **IntegraSignalV6** | `0xbdA381A883C084c5702329f796b95fE44773Fe2D` | Payment requests |

### Infrastructure (Layer 6)

| Contract | Address | Purpose |
|----------|---------|---------|
| **IntegraExecutorV6** | `0x786E015B709F0aAEb655416c4AA4020D66E54d96` | Meta-transactions |

## 💡 Usage Example

```javascript
import { ethers } from 'ethers';

// Import contract ABIs from package
const DocumentRegistryABI = require('@integraledger/smart-contracts-evm-v6/out/IntegraDocumentRegistryV6.sol/IntegraDocumentRegistryV6.json');

// Connect to contract
const documentRegistry = new ethers.Contract(
  '0x8609E5627933665D4576aAE992b13465fedecBde',
  DocumentRegistryABI.abi,
  signer
);

// Register a document
const tx = await documentRegistry.registerDocument(
  integraHash,
  documentHash,
  resolverAddress,
  referencedDocument,
  proofA, proofB, proofC,
  encryptedContactData
);

await tx.wait();
```

## 📚 Contract Features

### IntegraDocumentRegistryV6
- Document registration with optional ZK proofs
- Encrypted contact data (max 2KB)
- Resolver assignment (pluggable tokenization strategies)
- Document ownership transfers
- Emergency pause controls
- Hybrid pattern (direct user calls or backend executor calls)

### Layer 3 Resolvers
- **OwnershipResolverV6**: ERC-721 for unique ownership (deeds, titles)
- **SharesResolverV6**: ERC-20 Votes for fractional ownership with checkpoints
- **MultiPartyResolverV6**: ERC-1155 for multi-stakeholder documents

All resolvers support:
- Anonymous reservations (address unknown at reservation time)
- Attestation-based claiming (via EAS)
- Encrypted role labels (max 500 bytes)
- Trust graph integration (optional)

### Communication Layer
- **IntegraMessageV6**: Event-sourced workflow messaging
- **IntegraSignalV6**: Encrypted payment requests with dispute resolution

## 🔧 Development

```bash
# Clone repository
git clone https://github.com/IntegraLedger/smart-contracts-evm-v6.git
cd smart-contracts-evm-v6

# Install Foundry dependencies
forge install

# Compile contracts
forge build

# Run tests
forge test

# Run with gas reporting
forge test --gas-report
```

## 📊 Gas Costs (Polygon Mainnet)

| Operation | Estimated Gas | Cost @ 50gwei |
|-----------|---------------|---------------|
| Register Document | ~210,000 | ~$0.03 |
| Transfer Ownership | ~43,000 | ~$0.006 |
| Set Resolver | ~48,000 | ~$0.007 |
| Claim Token (ERC-721) | ~150,000 | ~$0.02 |
| Send Payment Request | ~250,000 | ~$0.035 |

## 🔐 Security

- ✅ All contracts enhanced with V5 best practices
- ✅ OpenZeppelin v5.0.0 libraries
- ✅ Emergency pause mechanisms
- ✅ Reentrancy protection
- ✅ Input validation with limits
- ✅ Role-based access control (GOVERNOR, OPERATOR, EXECUTOR)
- ✅ Upgradeable (UUPS)
- ✅ 25 tests passing (100%)

**External Review Score:** 9.25/10

## 📖 Documentation

Full documentation available in the repository:
- [Gas Analysis Report](./GAS_ANALYSIS_REPORT.md)
- [Polygon Deployment Guide](./POLYGON_DEPLOYMENT.md)
- [Complete Deployment Summary](./deployments/COMPLETE_POLYGON_DEPLOYMENT.md)
- [Security Review Response](./SECURITY_REVIEW_RESPONSE.md)
- [Field Limits Analysis](./FIELD_LIMITS_ANALYSIS.md)
- [Verification Report](./VERIFICATION_REPORT.md)

## 🌐 External Dependencies

**EAS (Ethereum Attestation Service) on Polygon:**
- EAS Contract: `0x5E634ef5355f45A855d02D66eCD687b1502AF790`
- Schema Registry: `0x7876EEF51A891E737AF8ba5A5E0f0Fd29073D5a7`
- Explorer: https://polygon.easscan.org/

## 📄 License

MIT License - see LICENSE file for details

## 🤝 Contributing

Issues and PRs welcome on GitHub: https://github.com/IntegraLedger/smart-contracts-evm-v6

---

**Version:** 6.0.0
**Network:** Polygon Mainnet (Chain ID: 137)
**Status:** ✅ Production Ready
**Deployment Cost:** ~$1.96 (2.45 POL)
