// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {INativeQueryVerifier} from "../contracts/Attestcoin.sol";
import {PayGoEscrow} from "../contracts/PayGoEscrow.sol";
import {CreditPassport} from "../contracts/CreditPassport.sol";
import {DemoAsset} from "../contracts/Demo.sol";
import {MockVerifier, MockChainInfo, HostileAsset, NonPayable} from "./Mocks.sol";

contract PayGoEscrowTest is Test {
    address constant VERIFIER = 0x0000000000000000000000000000000000000FD2;
    address constant CHAIN_INFO = 0x0000000000000000000000000000000000000fD3;
    uint64 constant CHAIN_KEY = 1;
    uint64 constant GRACE = 2000;
    uint64 constant CURE = 240;
    address constant ROUTER = address(0xA11CE);
    address constant CUSTODY_ROUTER = address(0xC0D1E);
    uint64 constant CUSTODY_WINDOW = 240;
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
        nft = new DemoAsset();
        address[] memory allowed = new address[](1); allowed[0] = address(nft);
        address[] memory allowedTokens = new address[](1); allowedTokens[0] = USDC;
        esc = new PayGoEscrow(CHAIN_KEY, ROUTER, GRACE, CURE, allowed, CUSTODY_ROUTER, CUSTODY_WINDOW, allowedTokens);
        uint256 tokenId = nft.mint(seller);
        amounts.push(40e6); amounts.push(20e6); amounts.push(20e6); amounts.push(20e6);
        vm.deal(seller, 10 ether);
        vm.startPrank(seller);
        nft.approve(address(esc), tokenId);
        orderId = esc.createOrder{value: 1 ether}(buyer, nft, tokenId, PAYEE, USDC, 100e6, 4, 10_000, 1000);   // 40 + 3×20
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
        assertEq(nft.ownerOf(1), address(esc));          // Completed ≠ transferred: pull, not push
        esc.claimAsset(orderId);
        assertEq(nft.ownerOf(1), buyer);
        (uint32 honored,, uint256 volume) = esc.passport().records(buyer);
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
        esc.claimAsset(orderId);
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
        assertEq(nft.ownerOf(1), address(esc));          // Defaulted ≠ transferred: pull, not push
        esc.withdrawAsset(orderId);
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
        uint256 id2 = esc.createOrder{value: 1 ether}(buyer, nft, t2, PAYEE, USDC, 100e6, 4, 20_000, 1000);
        vm.stopPrank();
        uint256[] memory a = esc.getOrder(id2).amounts;
        assertEq(a[0], 15e6);                  // 15% instead of 40%
        assertEq(a[1] + a[2] + a[3], 85e6);
        assertEq(esc.getOrder(orderId).amounts[0], 40e6);
    }

    // ---- WEB-audit-style hardening: whitelist + pull pattern (problem 1: NFT that bricks the release leg)

    function test_createOrder_rejectsUnlistedAsset() public {
        DemoAsset other = new DemoAsset();          // never passed to the escrow's constructor allowlist
        uint256 t = other.mint(seller);
        vm.startPrank(seller);
        other.approve(address(esc), t);
        vm.expectRevert("asset not allowlisted");
        esc.createOrder(buyer, other, t, PAYEE, USDC, 100e6, 4, 30_000, 1000);
        vm.stopPrank();
    }

    function test_claimAsset_hostileAssetDoesNotBrickSettleBatch() public {
        // A second escrow whose allowlist includes a HostileAsset (accepts the deposit leg, then always
        // reverts) alongside the normal DemoAsset — proves a bad release call cannot brick a shared
        // settle() batch that also carries a healthy order's proof.
        HostileAsset bad = new HostileAsset();
        address[] memory allowed = new address[](2); allowed[0] = address(nft); allowed[1] = address(bad);
        address[] memory allowedTokens = new address[](1); allowedTokens[0] = USDC;
        PayGoEscrow esc2 = new PayGoEscrow(CHAIN_KEY, ROUTER, GRACE, CURE, allowed, CUSTODY_ROUTER, CUSTODY_WINDOW, allowedTokens);

        uint256 tBad = bad.mint(seller);
        uint256 tGood = nft.mint(seller);
        vm.startPrank(seller);
        bad.approve(address(esc2), tBad);
        nft.approve(address(esc2), tGood);
        uint256 idBad = esc2.createOrder{value: 1 ether}(buyer, bad, tBad, PAYEE, USDC, 10e6, 1, 30_000, 1000);   // 1 installment: pays in full
        uint256 idGood = esc2.createOrder{value: 1 ether}(buyer, nft, tGood, PAYEE, USDC, 10e6, 1, 30_000, 1000);
        vm.stopPrank();

        // one settle() batch carries both orders' final (and only) installment
        uint64[] memory hs = new uint64[](2);
        bytes[] memory txs = new bytes[](2);
        INativeQueryVerifier.MerkleProof[] memory ps = new INativeQueryVerifier.MerkleProof[](2);
        hs[0] = 30_000; hs[1] = 30_000;
        txs[0] = _installmentTx(address(esc2), idBad, 10e6);
        txs[1] = _installmentTx(address(esc2), idGood, 10e6);
        ps[0] = INativeQueryVerifier.MerkleProof(bytes32(uint256(0)), new INativeQueryVerifier.MerkleProofEntry[](0));
        ps[1] = INativeQueryVerifier.MerkleProof(bytes32(uint256(1)), new INativeQueryVerifier.MerkleProofEntry[](0));

        esc2.settle(hs, txs, ps, INativeQueryVerifier.ContinuityProof(bytes32(0), new bytes32[](0)));   // must NOT revert

        assertEq(uint8(esc2.getOrder(idBad).status), uint8(PayGoEscrow.Status.Completed));
        assertEq(uint8(esc2.getOrder(idGood).status), uint8(PayGoEscrow.Status.Completed));

        vm.expectRevert("gotcha: release leg reverts");
        esc2.claimAsset(idBad);                         // the hostile order's own claim fails in isolation…

        esc2.claimAsset(idGood);                        // …but the sibling order's claim is unaffected
        assertEq(nft.ownerOf(tGood), buyer);
    }

    function _installmentTx(address escrowAddr, uint256 id, uint256 amount) internal pure returns (bytes memory) {
        return encodeTx(ROUTER, escrowAddr, id, 0, PAYEE, USDC, amount, 1);
    }

    // ---- Proof-of-Custody: chip attestation → match returns the bond, mismatch slashes it

    function encodeCustodyTx(address emitter, address escrowAddr, uint256 id, address chip, uint8 role, address submitter)
        internal pure returns (bytes memory)
    {
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = keccak256("PossessionAttested(address,uint256,address,uint8,address)");
        topics[1] = bytes32(uint256(uint160(escrowAddr)));
        topics[2] = bytes32(id);
        EvmV1Decoder.LogEntryTuple[] memory logs = new EvmV1Decoder.LogEntryTuple[](1);
        logs[0] = EvmV1Decoder.LogEntryTuple(emitter, topics, abi.encode(chip, role, submitter));
        bytes[] memory chunks = new bytes[](3);
        chunks[0] = abi.encode(uint64(0), uint64(0), address(0), false, address(0), uint256(0), bytes(""));
        chunks[1] = "";
        chunks[2] = abi.encode(uint8(1), uint64(50_000), logs, bytes(""));
        return abi.encode(uint8(2), chunks);
    }

    function settleCustodyOne(uint64 height, bytes memory txb, uint64 txIndex) internal {
        uint64[] memory hs = new uint64[](1); hs[0] = height;
        bytes[] memory txs = new bytes[](1); txs[0] = txb;
        INativeQueryVerifier.MerkleProof[] memory ps = new INativeQueryVerifier.MerkleProof[](1);
        ps[0] = INativeQueryVerifier.MerkleProof(bytes32(uint256(txIndex)), new INativeQueryVerifier.MerkleProofEntry[](0));
        esc.settleCustody(hs, txs, ps, INativeQueryVerifier.ContinuityProof(bytes32(0), new bytes32[](0)));
    }

    address constant CHIP = address(0xC41D);

    function test_custody_matchingChipReturnsBondToSeller() public {
        settleCustodyOne(10_000, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, CHIP, 0, seller), 50);   // Origin, submitted by the seller
        assertEq(esc.getOrder(orderId).chipId, CHIP);
        settleCustodyOne(10_001, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, CHIP, 1, buyer), 51);   // Delivery, same chip, submitted by the buyer
        assertTrue(esc.getOrder(orderId).custodyVerified);
        assertEq(esc.bondRecipient(orderId), seller);

        esc.withdrawBond(orderId);                              // resolve — credits the pooled claimable balance
        assertEq(esc.custodyBond(orderId), 0);
        assertEq(esc.claimableBond(seller), 1 ether);

        uint256 before = seller.balance;
        vm.prank(seller);
        esc.claimBond();                                        // pull — seller receives it
        assertEq(seller.balance, before + 1 ether);

        (uint32 confirmed, uint32 disputed) = esc.sellerPassport().records(seller);
        assertEq(confirmed, 1); assertEq(disputed, 0);
    }

    // SC-AUDIT-04: a mismatch pays NOBODY. A "chip" is a keypair, so any buyer can generate one and
    // manufacture a mismatch for free — paying them the bond would be a bounty on lying. Only a match is a
    // positive proof. The seller who really swapped the item still loses the bond; the buyer gains nothing.
    function test_custody_mismatchedChipBurnsBondAndPaysNobody() public {
        settleCustodyOne(10_000, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, CHIP, 0, seller), 50);          // Origin: real chip, real seller
        address forgedChip = address(0xBAD1D);
        settleCustodyOne(10_001, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, forgedChip, 1, buyer), 51);    // Delivery: any other key, real buyer
        assertTrue(esc.getOrder(orderId).custodyDisputed);
        assertEq(esc.bondRecipient(orderId), address(0xdEaD), "the bond resolves to the burn address");

        esc.withdrawBond(orderId);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        vm.expectRevert("nothing claimable");
        esc.claimBond();
        assertEq(buyer.balance, before, "no profit motive for forging a mismatch");
        assertEq(esc.claimableBond(address(0xdEaD)), 1 ether, "stranded: claimBond pays msg.sender, nobody is 0xdEaD");
        assertEq(esc.claimableBond(seller), 0, "and the seller does not get it back either");

        (uint32 confirmed, uint32 disputed) = esc.sellerPassport().records(seller);
        assertEq(confirmed, 0); assertEq(disputed, 1);
    }

    function test_custody_secondOriginAttestationIgnored() public {
        settleCustodyOne(10_000, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, CHIP, 0, seller), 50);
        address otherChip = address(0xAAAA);
        settleCustodyOne(10_001, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, otherChip, 0, seller), 51);   // a second "origin" attempt
        assertEq(esc.getOrder(orderId).chipId, CHIP);           // first still wins — can't be rebound
    }

    // SC-AUDIT-03 regression: a third party (or the buyer) squatting the Origin slot with someone else's
    // chip must be rejected — only the seller may bind role 0.
    function test_custody_originSquatByNonSellerRejected() public {
        settleCustodyOne(10_000, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, address(0xBADBAD), 0, buyer), 50);
        assertEq(esc.getOrder(orderId).chipId, address(0));      // squat rejected: chip stays unbound
        settleCustodyOne(10_001, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, CHIP, 0, seller), 51);
        assertEq(esc.getOrder(orderId).chipId, CHIP);             // the real seller's Origin binds cleanly afterward
    }

    function test_withdrawBond_timeoutFavorsSellerAbsentDispute() public {
        for (uint8 i; i < 4; i++) settleOne(10_000 + uint64(i) * 1000, goodTx(i), i);   // order Completed, no custody attestation ever submitted
        vm.expectRevert("not resolved");
        esc.withdrawBond(orderId);                              // window hasn't passed yet
        vm.roll(block.number + CUSTODY_WINDOW + 1);
        esc.withdrawBond(orderId);                              // silence is not evidence against the seller
        uint256 before = seller.balance;
        vm.prank(seller);
        esc.claimBond();
        assertEq(seller.balance, before + 1 ether);
    }

    // A buyer who never pays and never scans must not strand the seller's bond: a Defaulted order times
    // out to the seller exactly like a Completed one (silence is not evidence against the seller).
    function test_withdrawBond_timeoutAfterDefaultFavorsSeller() public {
        MockChainInfo(CHAIN_INFO).setHeight(20_000);
        esc.declareDefault(orderId);
        vm.roll(block.number + CURE + 1);
        esc.finalizeDefault(orderId);
        vm.expectRevert("not resolved");
        esc.withdrawBond(orderId);                              // custody window not over yet
        vm.roll(block.number + CUSTODY_WINDOW + 1);
        esc.withdrawBond(orderId);
        assertEq(esc.claimableBond(seller), 1 ether);
    }

    // SC-AUDIT-02 regression: a recipient that can't accept a bare value transfer must not brick the
    // per-order resolution — `withdrawBond` always finalizes; only the pull (`claimBond`) can fail, and
    // only for its own caller.
    function test_claimBond_nonPayableRecipientDoesNotBrickResolution() public {
        // Since SC-AUDIT-04 only the seller leg ever pays a real party, so that is where a recipient which
        // cannot accept native value still matters: an ordinary smart-contract wallet listing an order.
        NonPayable np = new NonPayable();
        vm.deal(address(np), 10 ether);
        uint256 t2 = nft.mint(address(np));
        np.exec(address(nft), 0, abi.encodeWithSignature("approve(address,uint256)", address(esc), t2));
        uint256 id2 = abi.decode(np.exec(address(esc), 1 ether, abi.encodeWithSignature(
            "createOrder(address,address,uint256,address,address,uint256,uint8,uint64,uint64)",
            buyer, address(nft), t2, PAYEE, USDC, uint256(100e6), uint8(4), uint64(40_000), uint64(1000))), (uint256));
        settleCustodyOne(40_000, encodeCustodyTx(CUSTODY_ROUTER, address(esc), id2, CHIP, 0, address(np)), 60);
        settleCustodyOne(40_001, encodeCustodyTx(CUSTODY_ROUTER, address(esc), id2, CHIP, 1, buyer), 61);   // match
        assertEq(esc.bondRecipient(id2), address(np));
        esc.withdrawBond(id2);                                  // resolution succeeds regardless of np's payability
        assertEq(esc.claimableBond(address(np)), 1 ether);
        vm.prank(address(np));
        vm.expectRevert("transfer failed");
        esc.claimBond();                                        // only the doomed pull reverts, isolated to np
    }

    function test_createOrder_requiresBondOrCleanCustodyRecord() public {
        uint256 t = nft.mint(seller);
        vm.startPrank(seller);
        nft.approve(address(esc), t);
        vm.expectRevert("post a custody bond, or build a clean delivery record");
        esc.createOrder(buyer, nft, t, PAYEE, USDC, 100e6, 4, 40_000, 1000);   // no value, no track record
        vm.stopPrank();

        // seed 4 clean chip-matched deliveries directly on the passport (equivalent to 4 real settleCustody flows)
        vm.startPrank(address(esc));
        for (uint8 i; i < 4; i++) esc.sellerPassport().record(seller, true);
        vm.stopPrank();

        vm.prank(seller);
        esc.createOrder(buyer, nft, t, PAYEE, USDC, 100e6, 4, 40_000, 1000);   // waived: no value sent, no revert
    }

    // ---- v5 security pass (docs/AUDIT.md SC-AUDIT-05/06/07/08)

    // SC-AUDIT-05: terminal statuses are absorbing, so a release used to be replayable. Once the same token
    // is escrowed again by a later order, replaying the old order's release drains the NEW order's collateral.
    function test_withdrawAsset_cannotBeReplayedAfterTheAssetIsRelisted() public {
        MockChainInfo(CHAIN_INFO).setHeight(20_000);
        esc.declareDefault(orderId);
        vm.roll(block.number + CURE + 1);
        esc.finalizeDefault(orderId);
        esc.withdrawAsset(orderId);                                  // the normal repossession flow
        assertEq(nft.ownerOf(1), seller);

        address buyer2 = address(0xB0B2);                            // seller re-lists the SAME token
        vm.startPrank(seller);
        nft.approve(address(esc), 1);
        uint256 id2 = esc.createOrder{value: 1 ether}(buyer2, nft, 1, PAYEE, USDC, 100e6, 4, 30_000, 1000);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), address(esc));

        vm.expectRevert("already released");
        esc.withdrawAsset(orderId);
        assertEq(nft.ownerOf(1), address(esc), "order 2's collateral is untouched");
        assertEq(uint8(esc.getOrder(id2).status), uint8(PayGoEscrow.Status.Active));
    }

    // SC-AUDIT-05, buyer leg: a past buyer who re-sells could pull the token back out of the new escrow.
    function test_claimAsset_cannotBeReplayedAfterTheAssetIsRelisted() public {
        for (uint8 i; i < 4; i++) settleOne(10_000 + uint64(i) * 1000, goodTx(i), i);
        esc.claimAsset(orderId);
        assertEq(nft.ownerOf(1), buyer);

        address buyer2 = address(0xB0B2);
        vm.deal(buyer, 10 ether);
        vm.startPrank(buyer);
        nft.approve(address(esc), 1);
        uint256 id2 = esc.createOrder{value: 1 ether}(buyer2, nft, 1, PAYEE, USDC, 100e6, 4, 30_000, 1000);
        vm.stopPrank();

        vm.expectRevert("already released");
        esc.claimAsset(orderId);
        assertEq(nft.ownerOf(1), address(esc));
        assertEq(uint8(esc.getOrder(id2).status), uint8(PayGoEscrow.Status.Active));
    }

    // SC-AUDIT-07: an unwritten order reads status Active with deadline 0, so the id of a future order could
    // be driven to Defaulted before it existed — and createOrder never resets the lifecycle fields.
    function test_declareDefault_rejectsUnknownOrder() public {
        uint256 futureId = esc.nextOrderId();
        vm.expectRevert("unknown order");
        esc.declareDefault(futureId);

        uint256 t = nft.mint(seller);
        vm.startPrank(seller);
        nft.approve(address(esc), t);
        uint256 id = esc.createOrder{value: 1 ether}(buyer, nft, t, PAYEE, USDC, 100e6, 4, 30_000, 1000);
        vm.stopPrank();
        assertEq(id, futureId);
        assertEq(uint8(esc.getOrder(id).status), uint8(PayGoEscrow.Status.Active), "born Active, not closed");
    }

    // SC-AUDIT-06: an unbounded schedule made deadline() panic inside _applyLog's filter chain, turning a
    // non-applicable log back into a batch-reverting poison log and leaving the order exitless.
    function test_createOrder_rejectsScheduleOverflowingUint64() public {
        uint256 t = nft.mint(seller);
        vm.startPrank(seller);
        nft.approve(address(esc), t);
        vm.expectRevert("schedule overflows uint64");
        esc.createOrder{value: 1 ether}(buyer, nft, t, PAYEE, USDC, 100e6, 2, type(uint64).max - 615, 1000);
        vm.stopPrank();
    }

    // SC-AUDIT-08: `volume` is informational, but a checked += let anyone pin it at max and panic every
    // later settle naming that buyer. Saturating keeps the facts flowing.
    function test_passport_volumeSaturatesInsteadOfBrickingTheBuyer() public {
        CreditPassport p = esc.passport();
        vm.startPrank(address(esc));
        p.record(buyer, true, type(uint256).max);
        p.record(buyer, true, 1);                                    // a checked += would panic here
        vm.stopPrank();
        (uint32 honored,, uint256 volume) = p.records(buyer);
        assertEq(volume, type(uint256).max);
        assertEq(honored, 2, "the payment fact is still recorded");
    }

    function test_passport_isSoulbound() public {
        settleOne(10_000, goodTx(0), 0);
        CreditPassport p = esc.passport();
        vm.expectRevert("soulbound");
        p.transferFrom(buyer, seller, uint160(buyer));
    }
}
