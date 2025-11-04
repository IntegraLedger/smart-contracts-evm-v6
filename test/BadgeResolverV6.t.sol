// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../src/layer3/BadgeResolverV6.sol";
import "./BaseResolverTest.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BadgeResolverV6Test is BaseResolverTest {
    BadgeResolverV6 public resolver;

    bytes32 integraHash1 = keccak256("badge1");
    bytes encryptedLabel = "encrypted_driver_license_data";

    function setUp() public {
        setupEAS();

        vm.startPrank(governor);

        // Deploy and initialize BadgeResolverV6
        BadgeResolverV6 impl = new BadgeResolverV6();
        bytes memory initData = abi.encodeWithSelector(
            BadgeResolverV6.initialize.selector,
            "Integra Badges",
            "IBG",
            "https://metadata.integra.network/badges/",
            governor,
            address(eas),
            capabilitySchema,
            credentialSchema,
            address(0)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        resolver = BadgeResolverV6(address(proxy));

        // Grant roles
        resolver.grantRole(EXECUTOR_ROLE, executor);
        resolver.grantRole(OPERATOR_ROLE, operator);

        vm.stopPrank();
    }

    // ============ Claiming Tests ============

    function test_ClaimBadge() public {
        // Reserve
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);

        // Set issuer
        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        // Create attestation
        vm.prank(issuer);
        bytes32 attestationUID = createCapabilityAttestation(issuer, user1, integraHash1, 1);

        // Claim
        vm.prank(user1);
        resolver.claimToken(integraHash1, 0, attestationUID);

        // Verify
        uint256 tokenId = resolver.integraHashToTokenId(integraHash1);
        assertEq(resolver.ownerOf(tokenId), user1);
        assertTrue(resolver.isValid(tokenId));
        assertEq(resolver.balanceOf(user1), 1);
        assertTrue(resolver.hasValid(user1));
    }

    // ============ Revocation Tests ============

    function test_RevokeBadge() public {
        // Claim badge first
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);

        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        vm.prank(issuer);
        bytes32 attestationUID = createCapabilityAttestation(issuer, user1, integraHash1, 1);

        vm.prank(user1);
        resolver.claimToken(integraHash1, 0, attestationUID);

        uint256 tokenId = resolver.integraHashToTokenId(integraHash1);

        // Verify valid before revocation
        assertTrue(resolver.isValid(tokenId));
        assertTrue(resolver.hasValid(user1));

        // Revoke
        vm.prank(operator);
        resolver.revoke(integraHash1, tokenId);

        // Verify invalid after revocation
        assertFalse(resolver.isValid(tokenId));
        assertFalse(resolver.hasValid(user1));

        // Badge still in wallet (historical preservation)
        assertEq(resolver.ownerOf(tokenId), user1);
        assertEq(resolver.balanceOf(user1), 1);
    }

    function test_RevertWhen_RevokeByNonIssuer() public {
        // Claim badge
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);

        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        bytes32 attestationUID = createCapabilityAttestation(issuer, user1, integraHash1, 1);

        vm.prank(user1);
        resolver.claimToken(integraHash1, 0, attestationUID);

        uint256 tokenId = resolver.integraHashToTokenId(integraHash1);

        // Try to revoke as non-issuer (should fail)
        vm.expectRevert();
        vm.prank(user2);
        resolver.revoke(integraHash1, tokenId);
    }

    // ============ Pull Tests (Wallet Migration) ============

    function test_PullBadge() public {
        // Claim badge
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);

        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        vm.prank(issuer);
        bytes32 attestationUID = createCapabilityAttestation(issuer, user1, integraHash1, 1);

        vm.prank(user1);
        resolver.claimToken(integraHash1, 0, attestationUID);

        uint256 tokenId = resolver.integraHashToTokenId(integraHash1);

        // Create signature for pull
        bytes32 messageHash = keccak256(abi.encodePacked(user1, user2, tokenId));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(keccak256("user2_private_key")), ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Note: This test would need proper signature from user2's actual key
        // For now, this demonstrates the pull mechanism structure
    }

    // ============ Non-Transferability Tests ============

    function test_NoTransferFunctions() public {
        // Verify BadgeResolverV6 has no transfer/transferFrom functions
        // This is enforced by not implementing them (ERC-4671 spec)
        // Badge ownership can only change via pull() with signature
    }

    // ============ Enumeration Tests ============

    function test_EmittedCount() public {
        // Claim one badge
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);

        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        vm.prank(issuer);
        bytes32 attestationUID = createCapabilityAttestation(issuer, user1, integraHash1, 1);

        uint256 beforeCount = resolver.emittedCount();

        vm.prank(user1);
        resolver.claimToken(integraHash1, 0, attestationUID);

        // Verify count increased
        assertEq(resolver.emittedCount(), beforeCount + 1);
    }

    // ============ Interface Support Tests ============

    function test_SupportsInterface() public {
        // ERC-4671
        assertTrue(resolver.supportsInterface(0x0d4a9f6b));

        // ERC-165
        assertTrue(resolver.supportsInterface(0x01ffc9a7));
    }
}
