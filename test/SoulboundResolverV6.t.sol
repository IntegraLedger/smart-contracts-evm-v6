// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../src/layer3/SoulboundResolverV6.sol";
import "./BaseResolverTest.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract SoulboundResolverV6Test is BaseResolverTest {
    SoulboundResolverV6 public resolver;

    bytes32 integraHash1 = keccak256("credential1");
    bytes32 integraHash2 = keccak256("credential2");

    bytes encryptedLabel = "encrypted_medical_license_data";

    function setUp() public {
        // Setup EAS from base
        setupEAS();

        vm.startPrank(governor);

        // Deploy and initialize SoulboundResolverV6
        SoulboundResolverV6 impl = new SoulboundResolverV6();
        bytes memory initData = abi.encodeWithSelector(
            SoulboundResolverV6.initialize.selector,
            "Integra Soulbound Credentials",
            "ISC",
            "https://metadata.integra.network/soulbound/",
            governor,
            address(eas),
            capabilitySchema,
            credentialSchema,
            address(0)  // No trust registry for testing
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        resolver = SoulboundResolverV6(address(proxy));

        // Grant roles
        resolver.grantRole(EXECUTOR_ROLE, executor);
        resolver.grantRole(OPERATOR_ROLE, operator);

        vm.stopPrank();
    }

    // ============ Reservation Tests ============

    function test_ReserveTokenAnonymous() public {
        vm.prank(executor);
        resolver.reserveTokenAnonymous(
            issuer,
            integraHash1,
            0,
            1,
            encryptedLabel
        );

        // Verify reservation
        (uint256[] memory tokenIds, bytes[] memory labels) = resolver.getAllEncryptedLabels(integraHash1);
        assertEq(tokenIds.length, 1);
        assertEq(labels[0], encryptedLabel);
    }

    function test_ReserveTokenForSpecificAddress() public {
        vm.prank(executor);
        resolver.reserveToken(
            issuer,
            integraHash1,
            0,
            user1,
            1
        );

        // Verify reservation
        uint256[] memory reserved = resolver.getReservedTokens(integraHash1, user1);
        assertEq(reserved.length, 1);
    }

    function test_RevertWhen_ReserveTokenTwice() public {
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);

        vm.expectRevert();
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);
    }

    function test_RevertWhen_ReserveTokenUnauthorized() public {
        vm.expectRevert();
        vm.prank(user1);  // Not executor
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);
    }

    // ============ Claiming Tests ============

    function test_ClaimToken() public {
        // Reserve
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);

        // Set document issuer
        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        // Create capability attestation with proper encoding
        bytes32 attestationUID = createCapabilityAttestation(
            issuer,
            user1,
            integraHash1,
            1  // CLAIM_TOKEN capability
        );

        // Claim token
        vm.prank(user1);
        resolver.claimToken(integraHash1, 0, attestationUID);

        // Verify claim
        (bool claimed, address claimedBy) = resolver.getClaimStatus(integraHash1, 0);
        assertTrue(claimed);
        assertEq(claimedBy, user1);
        assertEq(resolver.balanceOf(user1, 0), 1);
    }

    function test_RevertWhen_ClaimTokenTwice() public {
        // Setup and claim once
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);

        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        bytes32 attestationUID = createCapabilityAttestation(issuer, user1, integraHash1, 1);

        vm.prank(user1);
        resolver.claimToken(integraHash1, 0, attestationUID);

        // Try to claim again (should revert)
        vm.expectRevert();
        vm.prank(user1);
        resolver.claimToken(integraHash1, 0, attestationUID);
    }

    // ============ ERC-5192 Tests ============

    function test_TokenIsLocked() public {
        // Reserve and claim
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);

        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        bytes32 attestationUID = createCapabilityAttestation(issuer, user1, integraHash1, 1);

        vm.prank(user1);
        resolver.claimToken(integraHash1, 0, attestationUID);

        // Get tokenId
        uint256 tokenId = resolver.integraHashToTokenId(integraHash1);

        // Verify locked
        assertTrue(resolver.locked(tokenId));
    }

    function test_RevertWhen_TransferLockedToken() public {
        // Reserve and claim
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);

        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        bytes32 attestationUID = createCapabilityAttestation(issuer, user1, integraHash1, 1);

        vm.prank(user1);
        resolver.claimToken(integraHash1, 0, attestationUID);

        uint256 tokenId = resolver.integraHashToTokenId(integraHash1);

        // Try to transfer (should fail - token is locked)
        vm.expectRevert(abi.encodeWithSignature("TokenIsLocked(uint256)", tokenId));
        vm.prank(user1);
        resolver.transferFrom(user1, user2, tokenId);
    }

    // ============ Expiration Tests ============

    function test_SetExpiration() public {
        // Reserve and claim
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);

        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        bytes32 attestationUID = createCapabilityAttestation(issuer, user1, integraHash1, 1);

        vm.prank(user1);
        resolver.claimToken(integraHash1, 0, attestationUID);

        uint256 tokenId = resolver.integraHashToTokenId(integraHash1);

        // Set expiration
        uint256 expirationTime = block.timestamp + 365 days;
        vm.prank(operator);
        resolver.setExpirationDate(integraHash1, expirationTime);

        // Verify expiration
        assertEq(resolver.expirationDate(tokenId), expirationTime);
        assertFalse(resolver.isExpired(tokenId));

        // Fast forward past expiration
        vm.warp(block.timestamp + 366 days);
        assertTrue(resolver.isExpired(tokenId));
    }

    // ============ Cancellation Tests ============

    function test_CancelReservation() public {
        // Reserve
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);

        // Set issuer
        vm.prank(executor);
        resolver.setDocumentIssuer(integraHash1, issuer);

        // Cancel
        vm.prank(executor);
        resolver.cancelReservation(issuer, integraHash1, 0);

        // Verify cancelled
        (bool claimed, ) = resolver.getClaimStatus(integraHash1, 0);
        assertFalse(claimed);
    }

    // ============ Pause Tests ============

    function test_PauseUnpause() public {
        vm.prank(governor);
        resolver.pause();

        // Should fail when paused
        vm.expectRevert();
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);

        vm.prank(governor);
        resolver.unpause();

        // Should work when unpaused
        vm.prank(executor);
        resolver.reserveTokenAnonymous(issuer, integraHash1, 0, 1, encryptedLabel);
    }

    // ============ Interface Support Tests ============

    function test_SupportsInterface() public {
        // ERC-5192
        assertTrue(resolver.supportsInterface(0xb45a3c0e));

        // ERC-721
        assertTrue(resolver.supportsInterface(0x80ac58cd));

        // ERC-165
        assertTrue(resolver.supportsInterface(0x01ffc9a7));
    }
}
