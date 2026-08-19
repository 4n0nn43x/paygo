// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {INativeQueryVerifier, IChainInfo} from "../contracts/Attestcoin.sol";

/// @dev Etched at 0x…0FD2 in tests. txIndex is smuggled in merkleProof.root so tests control nullifiers.
contract MockVerifier {
    bool public fail;
    function setFail(bool f) external { fail = f; }
    function verifyAndEmit(uint64, uint64[] calldata, bytes[] calldata, INativeQueryVerifier.MerkleProof[] calldata, INativeQueryVerifier.ContinuityProof calldata)
        external view returns (bool)
    { require(!fail, "invalid proof"); return true; }
    function calculateTxIndex(INativeQueryVerifier.MerkleProof calldata p) external pure returns (uint64) { return uint64(uint256(p.root)); }
}

/// @dev Etched at 0x…0fD3 in tests.
contract MockChainInfo {
    uint64 public height;
    function setHeight(uint64 h) external { height = h; }
    function get_latest_attestation_height_and_hash(uint64) external view returns (IChainInfo.HeightHash memory) {
        return IChainInfo.HeightHash(height, bytes32(0), true, true);
    }
}
