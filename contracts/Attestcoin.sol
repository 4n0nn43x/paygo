// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @notice Block-prover precompile (0x…0FD2). Reverts on invalid proof, never returns false.
///         Batch form: up to 10 txs within 1000 source blocks sharing one continuity proof.
interface INativeQueryVerifier {
    struct MerkleProofEntry { bytes32 hash; bool isLeft; }
    struct MerkleProof { bytes32 root; MerkleProofEntry[] siblings; }
    struct ContinuityProof { bytes32 lowerEndpointDigest; bytes32[] roots; }

    function verifyAndEmit(
        uint64 chainKey,
        uint64[] calldata heights,
        bytes[] calldata encodedTransactions,
        MerkleProof[] calldata merkleProofs,
        ContinuityProof calldata sharedContinuityProof
    ) external returns (bool);

    function calculateTxIndex(MerkleProof calldata merkleProof) external view returns (uint64);
}

/// @notice Chain-info precompile (0x…0fD3): latest attested source height = the only trustless clock.
interface IChainInfo {
    struct HeightHash { uint64 height; bytes32 hash; bool isAttestation; bool exists; }
    function get_latest_attestation_height_and_hash(uint64 chainKey) external view returns (HeightHash memory);
}

INativeQueryVerifier constant VERIFIER = INativeQueryVerifier(0x0000000000000000000000000000000000000FD2);
IChainInfo constant CHAIN_INFO = IChainInfo(0x0000000000000000000000000000000000000fD3);
