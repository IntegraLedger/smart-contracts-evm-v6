// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../src/layer3/VaultResolverV6.sol";
import "./BaseResolverTest.sol";
import "./mocks/MockERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract VaultResolverV6Test is BaseResolverTest {
    VaultResolverV6 public resolver;
    MockERC20 public asset;

    bytes32 integraHash1 = keccak256("fund1");
    bytes encryptedLabel = "encrypted_pe_fund_terms";

    uint256 constant INITIAL_ASSETS = 1000000 * 10**18;

    function setUp() public {
        setupEAS();

        vm.startPrank(governor);

        // Deploy MockERC20
        asset = new MockERC20("USD Coin", "USDC");

        // Deploy and initialize VaultResolverV6
        VaultResolverV6 impl = new VaultResolverV6();
        bytes memory initData = abi.encodeWithSelector(
            VaultResolverV6.initialize.selector,
            "Integra Vault Shares",
            "IVS",
            address(asset),
            governor,
            address(eas),
            capabilitySchema,
            credentialSchema,
            address(0)  // No trust registry
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        resolver = VaultResolverV6(address(proxy));

        // Grant roles
        resolver.grantRole(EXECUTOR_ROLE, executor);
        resolver.grantRole(OPERATOR_ROLE, operator);

        // Mint assets to investors
        asset.mint(investor1, INITIAL_ASSETS);
        asset.mint(investor2, INITIAL_ASSETS);

        vm.stopPrank();
    }

    // ============ Reservation Tests ============

    function test_ReserveShares() public {
        vm.prank(executor);
        resolver.reserveTokenAnonymous(
            issuer,
            integraHash1,
            0,
            100000,
            encryptedLabel
        );

        // Verify reservation
        (uint256[] memory tokenIds, bytes[] memory labels) = resolver.getAllEncryptedLabels(integraHash1);
        assertEq(tokenIds.length, 1);
        assertEq(labels[0], encryptedLabel);
    }

    // ============ Claiming Tests ============

    function test_ClaimSharesAndDeposit() public {
        uint256 sharesToClaim = 10000;
        uint256 assetsToDeposit = 10000 * 10**18;

        // Reserve
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, sharesToClaim, encryptedLabel);

        // Set issuer
        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        // Create capability attestation
        bytes32 attestationUID = createCapabilityAttestation(issuer, investor1, integraHash1, 1);

        // Approve vault to spend assets
        vm.prank(investor1);
        asset.approve(address(resolver), assetsToDeposit);

        // Claim shares (this should trigger deposit)
        vm.prank(investor1);
        resolver.claimToken(integraHash1, sharesToClaim, attestationUID);

        // Verify shares received
        assertGt(resolver.balanceOf(investor1, 0), 0);
    }

    // ============ Lockup Tests ============

    function test_LockupPeriod() public {
        uint256 sharesToClaim = 10000;

        // Set lockup period (30 days)
        vm.prank(operator);
        resolver.setLockupPeriod(integraHash1, 30 days);

        // Reserve and claim
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, sharesToClaim, encryptedLabel);

        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        vm.prank(issuer);
        bytes32 attestationUID = createCapabilityAttestation(issuer, investor1, integraHash1, 1);

        vm.prank(investor1);
        asset.approve(address(resolver), INITIAL_ASSETS);

        vm.prank(investor1);
        resolver.claimToken(integraHash1, sharesToClaim, attestationUID);

        // Check locked
        (bool locked, uint256 releaseTime) = resolver.isLocked(integraHash1, investor1);
        assertTrue(locked);
        assertEq(releaseTime, block.timestamp + 30 days);

        // Try to withdraw during lockup (should fail)
        vm.expectRevert();
        vm.prank(investor1);
        resolver.redeem(sharesToClaim, investor1, investor1);

        // Fast forward past lockup
        vm.warp(block.timestamp + 31 days);

        // Should work now
        (bool lockedAfter, ) = resolver.isLocked(integraHash1, investor1);
        assertFalse(lockedAfter);
    }

    // ============ ERC-4626 Tests ============

    function test_ERC4626Interface() public {
        // Verify asset
        assertEq(address(resolver.asset()), address(asset));

        // Test conversion functions exist
        uint256 shares = resolver.convertToShares(1000);
        uint256 assets = resolver.convertToAssets(shares);

        // Basic sanity checks
        assertGt(shares, 0);
        assertGt(assets, 0);
    }

    // ============ Governance Tests ============

    function test_VotingPowerAutoDelegated() public {
        uint256 sharesToClaim = 10000;

        // Reserve and claim
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, sharesToClaim, encryptedLabel);

        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        vm.prank(issuer);
        bytes32 attestationUID = createCapabilityAttestation(issuer, investor1, integraHash1, 1);

        vm.prank(investor1);
        asset.approve(address(resolver), INITIAL_ASSETS);

        vm.prank(investor1);
        resolver.claimToken(integraHash1, sharesToClaim, attestationUID);

        // Verify auto-delegation
        assertEq(resolver.delegates(investor1), investor1);
        assertGt(resolver.getVotes(investor1), 0);
    }

    // ============ Pause Tests ============

    function test_PauseUnpause() public {
        vm.prank(governor);
        resolver.pause();

        vm.expectRevert();
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1000, encryptedLabel);

        vm.prank(governor);
        resolver.unpause();

        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1000, encryptedLabel);
    }

    // ============ Interface Support Tests ============

    function test_SupportsInterface() public {
        // ERC-165
        assertTrue(resolver.supportsInterface(0x01ffc9a7));
    }
}
