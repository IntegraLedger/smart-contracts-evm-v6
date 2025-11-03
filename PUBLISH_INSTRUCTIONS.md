# Publishing @integraledger/smart-contracts-evm-v6 to GitHub Packages

## ✅ What's Ready

The package is fully prepared for publication:
- ✅ `package.json` configured with @integraledger scope
- ✅ `.npmrc` configured for GitHub Packages
- ✅ README.md with usage instructions
- ✅ All contract sources, ABIs, and deployments included
- ✅ Package builds successfully (4.9 MB, 128 files)

## ❌ Current Issue

**Error:** `403 Forbidden - The token provided does not match expected scopes`

**Cause:** The GitHub token in `.npmrc` doesn't have `write:packages` permission.

## 🔧 How to Fix

### Option 1: Create New Token with Correct Permissions

1. Go to https://github.com/settings/tokens/new
2. Select these scopes:
   - ✅ `write:packages` (publish packages)
   - ✅ `read:packages` (download packages)
   - ✅ `delete:packages` (optional - manage packages)
   - ✅ `repo` (if private repository)
3. Click "Generate token"
4. Copy the token (starts with `ghp_`)
5. Update `.npmrc`:
   ```
   @integraledger:registry=https://npm.pkg.github.com/
   //npm.pkg.github.com/:_authToken=YOUR_NEW_TOKEN_HERE
   ```
6. Run: `npm publish`

### Option 2: Use Existing Token from Another Package

If you have a working token in another package:
```bash
cp /path/to/working/package/.npmrc .npmrc
npm publish
```

## 📦 What Will Be Published

Package: `@integraledger/smart-contracts-evm-v6@6.0.0`

**Contents:**
- Contract source files (src/)
- Compiled ABIs (out/)
- Deployment addresses (deployments/)
- Deployment scripts (script/)
- Documentation (*.md files)

**Size:** 4.9 MB (128 files)

## 🚀 After Publishing

Users can install with:
```bash
npm install @integraledger/smart-contracts-evm-v6
```

And use:
```javascript
// Import ABIs
const DocumentRegistry = require('@integraledger/smart-contracts-evm-v6/out/IntegraDocumentRegistryV6.sol/IntegraDocumentRegistryV6.json');

// Import deployment addresses
const deployments = require('@integraledger/smart-contracts-evm-v6/deployments/polygon-v6.txt');
```

## 📋 Package Info

- **Name:** @integraledger/smart-contracts-evm-v6
- **Version:** 6.0.0
- **Registry:** GitHub Packages (https://npm.pkg.github.com/)
- **Repository:** https://github.com/IntegraLedger/smart-contracts-evm-v6
- **License:** MIT

## 🔐 Security Note

The `.npmrc` file with auth token is in `.gitignore` and will NOT be committed to git.
Each developer needs their own GitHub token locally.

---

**To publish:** Get a token with `write:packages` scope and run `npm publish`
