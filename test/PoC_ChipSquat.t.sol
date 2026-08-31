// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {INativeQueryVerifier} from "../contracts/Attestcoin.sol";
import {PayGoEscrow} from "../contracts/PayGoEscrow.sol";
import {DemoAsset} from "../contracts/Demo.sol";
import {MockVerifier, MockChainInfo} from "./Mocks.sol";

/// @notice SC-AUDIT-03 (Variant A) regression. Was a High: `_applyCustodyLog`'s "first Origin
///         attestation wins" bound `chipId` to whatever `chip` value showed up first with role==0,
///         with no check on who submitted it — any third party could squat the slot with a throwaway
///         keypair before the real seller's real chip ever attested, later causing an honest seller's
///         bond to be wrongly slashed on a genuine, honest delivery scan.
///         Fix: `_applyCustodyLog` now requires `submitter == o.seller` for role==0 (Origin) and
///         `submitter == o.buyer` for role==1 (Delivery) — `submitter` is CustodyRouter's real,
///         unspoofable `msg.sender`, so a squatter's bogus attestation is now filtered like any other
///         inapplicable log, and the real seller's real chip binds cleanly afterward.
contract PoC_ChipSquat is Test {
    address constant VERIFIER = 0x0000000000000000000000000000000000000FD2;
    address constant CHAIN_INFO = 0x0000000000000000000000000000000000000fD3;
    uint64 constant CHAIN_KEY = 1;
    address constant ROUTER = address(0xA11CE);
    address constant CUSTODY_ROUTER = address(0xC0D1E);
    address constant USDC = address(0xBEEF);
    address constant PAYEE = address(0xFEE);

    PayGoEscrow esc;
    DemoAsset nft;
    address seller = address(0x5E11E2);   // honest seller, runs a real physical chip
    address buyer = address(0xB0B);
    address realChip = address(0xC41D);   // the asset's genuine, physically-embedded chip

    function setUp() public {
        vm.etch(VERIFIER, address(new MockVerifier()).code);
        vm.etch(CHAIN_INFO, address(new MockChainInfo()).code);
        nft = new DemoAsset();
        address[] memory allowed = new address[](1); allowed[0] = address(nft);
        address[] memory allowedTokens = new address[](1); allowedTokens[0] = USDC;
        esc = new PayGoEscrow(CHAIN_KEY, ROUTER, 2000, 240, allowed, CUSTODY_ROUTER, 240, allowedTokens);
        uint256 tokenId = nft.mint(seller);
        vm.deal(seller, 10 ether);
        vm.startPrank(seller);
        nft.approve(address(esc), tokenId);
        esc.createOrder{value: 1 ether}(buyer, nft, tokenId, PAYEE, USDC, 100e6, 1, 10_000, 1000);
        vm.stopPrank();
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

    function test_squatAttemptRejected_thenRealSellerBindsCleanly() public {
        uint256 orderId = 1;

        // Attacker submits a bogus role==0 (Origin) attestation as themselves — `submitter != o.seller`
        // — before the real seller's chip ever attests.
        address squatterChip = address(0xBADBAD);
        settleCustodyOne(10_000, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, squatterChip, 0, address(this)), 1);
        assertEq(esc.getOrder(orderId).chipId, address(0), "squat rejected: chip stays unbound");

        // The real seller's real chip attests next — binds cleanly since nothing squatted the slot.
        settleCustodyOne(10_001, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, realChip, 0, seller), 2);
        assertEq(esc.getOrder(orderId).chipId, realChip);

        // The buyer's honest delivery scan of the same real chip now correctly matches.
        settleCustodyOne(10_002, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, realChip, 1, buyer), 3);
        assertTrue(esc.getOrder(orderId).custodyVerified, "honest delivery correctly confirmed");
        assertEq(esc.bondRecipient(orderId), seller, "bond correctly returns to the honest seller");

        (uint32 confirmed, uint32 disputed) = esc.sellerPassport().records(seller);
        assertEq(confirmed, 1);
        assertEq(disputed, 0, "honest seller's passport is clean, unaffected by the squat attempt");
    }

    /// @dev The buyer squatting their own order's Origin slot (to try to force a later mismatch against
    ///      the real seller) is rejected identically — `submitter == buyer` still fails `== o.seller`.
    function test_buyerCannotSquatOwnOrdersOriginSlot() public {
        uint256 orderId = 1;
        settleCustodyOne(10_000, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, address(0xBADBAD), 0, buyer), 1);
        assertEq(esc.getOrder(orderId).chipId, address(0));
    }
}
