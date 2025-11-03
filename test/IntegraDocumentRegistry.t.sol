// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/layer2/IntegraDocumentRegistryV6.sol";
import "../src/layer6/IntegraVerifierRegistryV6.sol";
import "./mocks/MockVerifier.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract IntegraDocumentRegistryV6Test is Test {
    IntegraDocumentRegistryV6 public registry;
    IntegraVerifierRegistryV6 public verifierRegistry;
    MockVerifier public mockVerifier;

    address public governor = address(0x1);
    address public executor = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public resolver1 = address(0x5);
    address public resolver2 = address(0x6);

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    // Test data
    bytes32 integraHash1 = keccak256("document1");
    bytes32 integraHash2 = keccak256("document2");
    bytes32 documentHash1 = keccak256("content1");
    bytes32 documentHash2 = keccak256("content2");
    string encryptedData = "encrypted_contact_data";

    uint256[2] proofA = [uint256(1), uint256(2)];
    uint256[2][2] proofB = [[uint256(3), uint256(4)], [uint256(5), uint256(6)]];
    uint256[2] proofC = [uint256(7), uint256(8)];

    function setUp() public {
        vm.startPrank(governor);

        // Deploy mock verifier
        mockVerifier = new MockVerifier();

        // Deploy and initialize VerifierRegistry
        IntegraVerifierRegistryV6 vrImpl = new IntegraVerifierRegistryV6();
        bytes memory vrInitData = abi.encodeWithSelector(
            IntegraVerifierRegistryV6.initialize.selector,
            governor
        );
        ERC1967Proxy vrProxy = new ERC1967Proxy(address(vrImpl), vrInitData);
        verifierRegistry = IntegraVerifierRegistryV6(address(vrProxy));

        // Register mock verifier
        verifierRegistry.registerVerifier(
            address(mockVerifier),
            "BasicAccessV1Poseidon",
            "v1"
        );

        // Deploy and initialize DocumentRegistry
        IntegraDocumentRegistryV6 impl = new IntegraDocumentRegistryV6();
        bytes memory initData = abi.encodeWithSelector(
            IntegraDocumentRegistryV6.initialize.selector,
            governor,
            address(verifierRegistry)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        registry = IntegraDocumentRegistryV6(address(proxy));

        // Grant executor role to executor address
        registry.grantRole(EXECUTOR_ROLE, executor);

        // Approve resolvers
        registry.setResolverApproval(resolver1, true);
        registry.setResolverApproval(resolver2, true);

        vm.stopPrank();
    }

    // ============ Registration Tests ============

    function test_RegisterDocument_Direct() public {
        vm.prank(user1);
        bytes32 result = registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0), // no reference
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        assertEq(result, integraHash1);

        IntegraDocumentRegistryV6.DocumentRecord memory doc = registry.getDocument(integraHash1);
        assertEq(doc.owner, user1);
        assertEq(doc.documentHash, documentHash1);
        assertEq(doc.resolver, resolver1);
        assertTrue(doc.exists);
    }

    function test_RegisterDocument_Executor() public {
        vm.prank(executor);
        bytes32 result = registry.registerDocumentFor(
            user1,
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        assertEq(result, integraHash1);

        IntegraDocumentRegistryV6.DocumentRecord memory doc = registry.getDocument(integraHash1);
        assertEq(doc.owner, user1);
    }

    function test_RegisterDocument_WithReference() public {
        // Register parent document
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        // Register child document with reference
        vm.prank(user2);
        bytes32 result = registry.registerDocument(
            integraHash2,
            documentHash2,
            resolver1,
            integraHash1, // reference to parent
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        assertEq(result, integraHash2);

        IntegraDocumentRegistryV6.DocumentRecord memory doc = registry.getDocument(integraHash2);
        assertEq(doc.referencedDocument, integraHash1);
    }

    function test_RevertWhen_InvalidResolver() public {
        vm.expectRevert();
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            address(0x999), // unapproved resolver
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );
    }

    function test_RevertWhen_DocumentAlreadyExists() public {
        vm.startPrank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        // Try to register again
        vm.expectRevert();
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );
        vm.stopPrank();
    }

    function test_RevertWhen_EncryptedDataTooLarge() public {
        string memory largeData = new string(11000); // > 10KB limit

        vm.expectRevert();
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            largeData
        );
    }

    function test_RevertWhen_InvalidProof() public {
        // Register parent
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        // Set verifier to reject proofs
        vm.prank(governor);
        mockVerifier.setShouldAcceptProof(false);

        // Try to register with reference (should fail on proof)
        vm.expectRevert();
        vm.prank(user2);
        registry.registerDocument(
            integraHash2,
            documentHash2,
            resolver1,
            integraHash1,
            proofA,
            proofB,
            proofC,
            encryptedData
        );
    }

    // ============ Resolver Tests ============

    function test_SetResolver_Direct() public {
        // Register document
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        // Change resolver
        vm.prank(user1);
        registry.setResolver(integraHash1, resolver2);

        IntegraDocumentRegistryV6.DocumentRecord memory doc = registry.getDocument(integraHash1);
        assertEq(doc.resolver, resolver2);
    }

    function test_SetResolver_Executor() public {
        // Register document
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        // Change resolver via executor
        vm.prank(executor);
        registry.setResolverFor(user1, integraHash1, resolver2);

        IntegraDocumentRegistryV6.DocumentRecord memory doc = registry.getDocument(integraHash1);
        assertEq(doc.resolver, resolver2);
    }

    function test_RevertWhen_SetResolverNotOwner() public {
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        // user2 tries to change resolver
        vm.expectRevert();
        vm.prank(user2);
        registry.setResolver(integraHash1, resolver2);
    }

    // ============ Ownership Transfer Tests ============

    function test_TransferOwnership_Direct() public {
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        vm.prank(user1);
        registry.transferDocumentOwnership(integraHash1, user2, "Transfer to user2");

        IntegraDocumentRegistryV6.DocumentRecord memory doc = registry.getDocument(integraHash1);
        assertEq(doc.owner, user2);
    }

    function test_TransferOwnership_Executor() public {
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        vm.prank(executor);
        registry.transferDocumentOwnershipFor(user1, integraHash1, user2, "Transfer to user2");

        IntegraDocumentRegistryV6.DocumentRecord memory doc = registry.getDocument(integraHash1);
        assertEq(doc.owner, user2);
    }

    function test_RevertWhen_TransferOwnershipNotOwner() public {
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        vm.expectRevert();
        vm.prank(user2);
        registry.transferDocumentOwnership(integraHash1, user2, "Steal document");
    }

    // ============ Pause Tests ============

    function test_Pause() public {
        vm.prank(governor);
        registry.pause();

        assertTrue(registry.paused());
    }

    function test_RevertWhen_RegisterDocumentWhenPaused() public {
        vm.prank(governor);
        registry.pause();

        vm.expectRevert();
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );
    }

    function test_Unpause() public {
        vm.startPrank(governor);
        registry.pause();
        registry.unpause();
        vm.stopPrank();

        assertFalse(registry.paused());

        // Should be able to register after unpause
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );
    }

    // ============ View Function Tests ============

    function test_GetDocumentOwner() public {
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        address owner = registry.getDocumentOwner(integraHash1);
        assertEq(owner, user1);
    }

    function test_IsDocumentOwner() public {
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        assertTrue(registry.isDocumentOwner(integraHash1, user1));
        assertFalse(registry.isDocumentOwner(integraHash1, user2));
    }

    function test_GetDocumentsBatch() public {
        vm.startPrank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        registry.registerDocument(
            integraHash2,
            documentHash2,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );
        vm.stopPrank();

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = integraHash1;
        hashes[1] = integraHash2;

        IntegraDocumentRegistryV6.DocumentRecord[] memory docs = registry.getDocumentsBatch(hashes);
        assertEq(docs.length, 2);
        assertEq(docs[0].owner, user1);
        assertEq(docs[1].owner, user1);
    }

    function test_ExistsBatch() public {
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = integraHash1;
        hashes[1] = integraHash2;

        bool[] memory exists = registry.existsBatch(hashes);
        assertTrue(exists[0]);
        assertFalse(exists[1]);
    }

    // ============ Gas Benchmarks ============

    function test_Gas_RegisterDocument_NoReference() public {
        vm.prank(user1);
        uint256 gasBefore = gasleft();
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas used (register, no reference)", gasUsed);
    }

    function test_Gas_RegisterDocument_WithReference() public {
        // Register parent
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        // Register child with reference
        vm.prank(user2);
        uint256 gasBefore = gasleft();
        registry.registerDocument(
            integraHash2,
            documentHash2,
            resolver1,
            integraHash1,
            proofA,
            proofB,
            proofC,
            encryptedData
        );
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas used (register, with reference)", gasUsed);
    }

    function test_Gas_RegisterDocumentFor() public {
        vm.prank(executor);
        uint256 gasBefore = gasleft();
        registry.registerDocumentFor(
            user1,
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas used (registerFor, executor)", gasUsed);
    }

    function test_Gas_SetResolver() public {
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        vm.prank(user1);
        uint256 gasBefore = gasleft();
        registry.setResolver(integraHash1, resolver2);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas used (setResolver)", gasUsed);
    }

    function test_Gas_TransferOwnership() public {
        vm.prank(user1);
        registry.registerDocument(
            integraHash1,
            documentHash1,
            resolver1,
            bytes32(0),
            proofA,
            proofB,
            proofC,
            encryptedData
        );

        vm.prank(user1);
        uint256 gasBefore = gasleft();
        registry.transferDocumentOwnership(integraHash1, user2, "Transfer ownership");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas used (transferOwnership)", gasUsed);
    }
}
