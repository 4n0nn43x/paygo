// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {INativeQueryVerifier} from "../contracts/Attestcoin.sol";
import {PayGoEscrow} from "../contracts/PayGoEscrow.sol";
import {CreditPassport} from "../contracts/CreditPassport.sol";
import {DemoAsset} from "../contracts/Demo.sol";
import {MockVerifier, MockChainInfo} from "./Mocks.sol";

contract PayGoEscrowTest is Test {
    address constant VERIFIER = 0x0000000000000000000000000000000000000FD2;
    address constant CHAIN_INFO = 0x0000000000000000000000000000000000000fD3;
    uint64 constant CHAIN_KEY = 1;
    uint64 constant GRACE = 2000;
    uint64 constant CURE = 240;
    address constant ROUTER = address(0xA11CE);
    address constant USDC = address(0xBEEF);
    address constant PAYEE = address(0xFEE);
    address seller = address(0x5E11E2);
    address buyer = address(0xB0B);

    PayGoEscrow esc;
    DemoAsset nft;
    uint256 orderId;
    uint256[] amounts;

    function setUp() public {
        vm.etch(VERIFIER, address(new MockVerifier()).code);
        vm.etch(CHAIN_INFO, address(new MockChainInfo()).code);
        esc = new PayGoEscrow(CHAIN_KEY, ROUTER, GRACE, CURE);
        nft = new DemoAsset();
        uint256 tokenId = nft.mint(seller);
        amounts.push(40e6); amounts.push(20e6); amounts.push(20e6); amounts.push(20e6);
        vm.startPrank(seller);
        nft.approve(address(esc), tokenId);
        orderId = esc.createOrder(buyer, nft, tokenId, PAYEE, USDC, 100e6, 4, 10_000, 1000);   // 40 + 3×20
        vm.stopPrank();
        MockChainInfo(CHAIN_INFO).setHeight(9_000);
    }

    // ---- fixture builders (EvmV1 encoding: abi(uint8 txType, bytes[3] chunks), receipt = chunk 2)

    function encodeTx(address emitter, address escrow, uint256 id, uint8 no, address payee, address token, uint256 amount, uint8 status)
        internal pure returns (bytes memory)
    {
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = keccak256("InstallmentPaid(address,uint256,uint8,address,address,address,uint256)");
        topics[1] = bytes32(uint256(uint160(escrow)));
        topics[2] = bytes32(id);
        EvmV1Decoder.LogEntryTuple[] memory logs = new EvmV1Decoder.LogEntryTuple[](1);
        logs[0] = EvmV1Decoder.LogEntryTuple(emitter, topics, abi.encode(no, address(0xCAFE), payee, token, amount));
        bytes[] memory chunks = new bytes[](3);
        chunks[0] = abi.encode(uint64(0), uint64(0), address(0), false, address(0), uint256(0), bytes(""));
        chunks[1] = "";
        chunks[2] = abi.encode(status, uint64(50_000), logs, bytes(""));
        return abi.encode(uint8(2), chunks);
    }

    function goodTx(uint8 no) internal view returns (bytes memory) {
        return encodeTx(ROUTER, address(esc), orderId, no, PAYEE, USDC, amounts[no], 1);
    }

    function settleOne(uint64 height, bytes memory txb, uint64 txIndex) internal {
        uint64[] memory hs = new uint64[](1); hs[0] = height;
        bytes[] memory txs = new bytes[](1); txs[0] = txb;
        INativeQueryVerifier.MerkleProof[] memory ps = new INativeQueryVerifier.MerkleProof[](1);
        ps[0] = INativeQueryVerifier.MerkleProof(bytes32(uint256(txIndex)), new INativeQueryVerifier.MerkleProofEntry[](0));
        esc.settle(hs, txs, ps, INativeQueryVerifier.ContinuityProof(bytes32(0), new bytes32[](0)));
    }

    // ---- happy path

    function test_fullLifecycle_assetToBuyer() public {
        for (uint8 i; i < 4; i++) settleOne(10_000 + uint64(i) * 1000, goodTx(i), i);
        assertEq(uint8(esc.getOrder(orderId).status), uint8(PayGoEscrow.Status.Completed));
        assertEq(nft.ownerOf(1), buyer);
        (uint32 honored,, uint128 volume) = esc.passport().records(buyer);
        assertEq(honored, 4);
        assertEq(volume, 100e6);
        assertEq(esc.passport().depositBps(buyer), 1500);
        assertEq(esc.passport().ownerOf(uint160(buyer)), buyer);
        assertTrue(esc.passport().locked(uint160(buyer)));
    }

    function test_batch_manyInstallmentsOneProof() public {
        uint64[] memory hs = new uint64[](4);
        bytes[] memory txs = new bytes[](4);
        INativeQueryVerifier.MerkleProof[] memory ps = new INativeQueryVerifier.MerkleProof[](4);
        for (uint8 i; i < 4; i++) {
            hs[i] = 9_990 + i; txs[i] = goodTx(i);
            ps[i] = INativeQueryVerifier.MerkleProof(bytes32(uint256(i)), new INativeQueryVerifier.MerkleProofEntry[](0));
        }
        esc.settle(hs, txs, ps, INativeQueryVerifier.ContinuityProof(bytes32(0), new bytes32[](0)));
        assertEq(nft.ownerOf(1), buyer);
    }

    // ---- the 5 checks

    function test_replay_rejected() public {
        settleOne(10_000, goodTx(0), 7);
        vm.expectRevert("replayed");
        settleOne(10_000, goodTx(0), 7);
    }

    function test_invalidProof_reverts() public {
        MockVerifier(VERIFIER).setFail(true);
        vm.expectRevert("invalid proof");
        settleOne(10_000, goodTx(0), 0);
    }

    function test_failedTx_notCredited() public {
        settleOne(10_000, encodeTx(ROUTER, address(esc), orderId, 0, PAYEE, USDC, amounts[0], 0), 0);
        assertFalse(esc.paid(orderId, 0));
    }

    function test_forgedEmitter_notCredited() public {
        settleOne(10_000, encodeTx(address(0xBAD), address(esc), orderId, 0, PAYEE, USDC, amounts[0], 1), 0);
        assertFalse(esc.paid(orderId, 0));
    }

    function test_wrongEscrow_notCredited() public {
        settleOne(10_000, encodeTx(ROUTER, address(0xBAD), orderId, 0, PAYEE, USDC, amounts[0], 1), 0);
        assertFalse(esc.paid(orderId, 0));
    }

    function test_underpaid_wrongPayee_wrongToken_notCredited() public {
        settleOne(10_000, encodeTx(ROUTER, address(esc), orderId, 0, PAYEE, USDC, amounts[0] - 1, 1), 0);
        settleOne(10_000, encodeTx(ROUTER, address(esc), orderId, 0, address(0xBAD), USDC, amounts[0], 1), 1);
        settleOne(10_000, encodeTx(ROUTER, address(esc), orderId, 0, PAYEE, address(0xBAD), amounts[0], 1), 2);
        assertFalse(esc.paid(orderId, 0));
    }

    function test_latePayment_notCredited() public {
        settleOne(10_001, goodTx(0), 0);
        assertFalse(esc.paid(orderId, 0));
    }

    // ---- state machine: default / cure / finalize

    function test_declareDefault_needsOverdueOnAttestedClock() public {
        MockChainInfo(CHAIN_INFO).setHeight(10_000 + GRACE);        // == deadline+grace: not yet
        vm.expectRevert("not overdue");
        esc.declareDefault(orderId);
        MockChainInfo(CHAIN_INFO).setHeight(10_000 + GRACE + 1);
        esc.declareDefault(orderId);
        assertEq(uint8(esc.getOrder(orderId).status), uint8(PayGoEscrow.Status.DefaultAsserted));
    }

    function test_cure_onTimeProofDuringWindow() public {
        MockChainInfo(CHAIN_INFO).setHeight(20_000);
        esc.declareDefault(orderId);
        settleOne(10_000, goodTx(0), 0);                              // paid at height <= deadline
        assertEq(uint8(esc.getOrder(orderId).status), uint8(PayGoEscrow.Status.Active));
        vm.roll(block.number + CURE + 1);
        vm.expectRevert("not asserted");
        esc.finalizeDefault(orderId);
    }

    function test_finalizeDefault_assetBackToSeller() public {
        settleOne(10_000, goodTx(0), 0);                              // deposit paid, then silence
        MockChainInfo(CHAIN_INFO).setHeight(20_000);
        esc.declareDefault(orderId);
        vm.expectRevert("cure window open");
        esc.finalizeDefault(orderId);
        vm.roll(block.number + CURE + 1);
        esc.finalizeDefault(orderId);
        assertEq(nft.ownerOf(1), seller);
        (, uint32 defaulted,) = esc.passport().records(buyer);
        assertEq(defaulted, 1);
        settleOne(11_000, goodTx(1), 1);          // now a no-op, not a revert
        assertFalse(esc.paid(orderId, 1));
    }

    function test_declareDefault_targetsEarliestUnpaid() public {
        settleOne(10_000, goodTx(0), 0);
        settleOne(12_000, goodTx(2), 2);
        MockChainInfo(CHAIN_INFO).setHeight(20_000);
        esc.declareDefault(orderId);
        assertEq(esc.getOrder(orderId).disputedNo, 1);
    }

    function test_noSelfDealing() public {
        uint256 t = nft.mint(seller);
        vm.startPrank(seller);
        nft.approve(address(esc), t);
        vm.expectRevert("no self-dealing");
        esc.createOrder(seller, nft, t, PAYEE, USDC, 100e6, 4, 20_000, 1000);
        vm.stopPrank();
    }

    // MEDIUM-1 regression: a poison log (already-paid installment) co-located with a fresh one
    // must not brick the fresh one. Encode a single tx carrying two InstallmentPaid logs.
    function test_batch_poisonLogDoesNotBrickSibling() public {
        settleOne(10_000, goodTx(0), 0);                 // installment 0 paid
        // tx with logs for installment 0 (already paid → skipped) and installment 1 (fresh → applied)
        bytes memory txb = _twoLogTx();
        uint64[] memory hs = new uint64[](1); hs[0] = 11_000;
        bytes[] memory txs = new bytes[](1); txs[0] = txb;
        INativeQueryVerifier.MerkleProof[] memory ps = new INativeQueryVerifier.MerkleProof[](1);
        ps[0] = INativeQueryVerifier.MerkleProof(bytes32(uint256(99)), new INativeQueryVerifier.MerkleProofEntry[](0));
        esc.settle(hs, txs, ps, INativeQueryVerifier.ContinuityProof(bytes32(0), new bytes32[](0)));
        assertTrue(esc.paid(orderId, 1));               // sibling settled despite the poison log
    }

    function _twoLogTx() internal view returns (bytes memory) {
        EvmV1Decoder.LogEntry[] memory _l; _l;
        bytes32 sig = keccak256("InstallmentPaid(address,uint256,uint8,address,address,address,uint256)");
        EvmV1Decoder.LogEntryTuple[] memory logs = new EvmV1Decoder.LogEntryTuple[](2);
        for (uint8 k; k < 2; k++) {
            bytes32[] memory topics = new bytes32[](3);
            topics[0] = sig; topics[1] = bytes32(uint256(uint160(address(esc)))); topics[2] = bytes32(orderId);
            logs[k] = EvmV1Decoder.LogEntryTuple(ROUTER, topics, abi.encode(k, address(0xCAFE), PAYEE, USDC, amounts[k]));
        }
        bytes[] memory chunks = new bytes[](3);
        chunks[0] = abi.encode(uint64(0), uint64(0), address(0), false, address(0), uint256(0), bytes(""));
        chunks[1] = "";
        chunks[2] = abi.encode(uint8(1), uint64(50_000), logs, bytes(""));
        return abi.encode(uint8(2), chunks);
    }

    function test_createOrder_mustBeEpochAligned() public {
        vm.prank(seller);
        vm.expectRevert("not epoch-aligned");
        esc.createOrder(buyer, nft, 1, PAYEE, USDC, 100e6, 4, 10_001, 1000);
    }

    function test_passport_reducesDepositOnSecondPurchase() public {
        for (uint8 i; i < 4; i++) settleOne(10_000 + uint64(i) * 1000, goodTx(i), i);
        uint256 t2 = nft.mint(seller);
        vm.startPrank(seller);
        nft.approve(address(esc), t2);
        uint256 id2 = esc.createOrder(buyer, nft, t2, PAYEE, USDC, 100e6, 4, 20_000, 1000);
        vm.stopPrank();
        uint256[] memory a = esc.getOrder(id2).amounts;
        assertEq(a[0], 15e6);                  // 15% instead of 40%
        assertEq(a[1] + a[2] + a[3], 85e6);
        assertEq(esc.getOrder(orderId).amounts[0], 40e6);
    }

    function test_passport_isSoulbound() public {
        settleOne(10_000, goodTx(0), 0);
        CreditPassport p = esc.passport();
        vm.expectRevert("soulbound");
        p.transferFrom(buyer, seller, uint160(buyer));
    }
}
