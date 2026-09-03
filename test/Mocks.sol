// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {INativeQueryVerifier, IChainInfo} from "../contracts/Attestcoin.sol";

/// @dev A contract with no `receive`/payable `fallback` — stands in for the class of recipient
///      (bespoke multisig, vault, minimal account contract) that can never accept a bare `.call{value}`.
contract NonPayable {
    /// @dev Lets the wallet act as a seller (approve + createOrder) while still being unable to ACCEPT a
    ///      bare value transfer — `receive`/`fallback` are what a payout needs, not what a call needs.
    function exec(address target, uint256 value, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        require(ok, "exec failed");
        return ret;
    }
}

/// @dev An asset that accepts exactly one transfer (the deposit leg, seller → escrow, at createOrder)
///      then always reverts — simulates a buggy/hostile seller-supplied ERC-721. Used to prove
///      `claimAsset`/`withdrawAsset` isolate that failure from `settle`/`finalizeDefault`.
contract HostileAsset is ERC721("Hostile", "BAD") {
    uint256 public next = 1;
    bool depositedOnce;
    function mint(address to) external returns (uint256 id) { id = next++; _mint(to, id); }
    function transferFrom(address from, address to, uint256 id) public override {
        require(!depositedOnce, "gotcha: release leg reverts");
        depositedOnce = true;
        super.transferFrom(from, to, id);
    }
}

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
