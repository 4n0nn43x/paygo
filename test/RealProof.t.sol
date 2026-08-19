// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";

/// @dev Real proofs captured from the CC3 testnet prover (test/fixtures.json, Sepolia block 11524435).
///      The precompile itself can't run in forge; this pins our decoding assumptions to real bytes.
contract RealProofTest is Test {
    function test_realTxBytes_decode() public view {
        string memory j = vm.readFile("test/fixtures.json");
        bytes memory txBytes = vm.parseJsonBytes(j, ".single.txBytes");
        assertEq(vm.parseJsonUint(j, ".single.headerNumber"), 11524435);

        assertEq(EvmV1Decoder.getTransactionType(txBytes), 2);
        EvmV1Decoder.ReceiptFields memory r = EvmV1Decoder.decodeReceiptFields(txBytes);
        assertEq(r.receiptStatus, 1);
        assertEq(r.receiptLogs.length, 1);
        // ERC20 Transfer(address,address,uint256) from 0x1c7d…7238 — the tx's `to`
        assertEq(r.receiptLogs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(r.receiptLogs[0].address_, 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);
        assertEq(EvmV1Decoder.decodeCommonTxFields(txBytes).to, 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238);
    }

    function test_realBatch_sharesOneContinuityProof() public view {
        string memory j = vm.readFile("test/fixtures.json");
        assertEq(vm.parseJsonUint(j, ".batch.fromHeader"), 11524435);
        assertEq(vm.parseJsonUint(j, ".batch.toHeader"), 11524435);
        bytes32[] memory roots = vm.parseJsonBytes32Array(j, ".batch.continuityProof.roots");
        assertGt(roots.length, 0);
        assertEq(vm.parseJsonUint(j, ".batch.merkleProofs[1].txIndex"), 1);
    }
}
