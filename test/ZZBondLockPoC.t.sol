// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {INativeQueryVerifier} from "../contracts/Attestcoin.sol";
import {PayGoEscrow} from "../contracts/PayGoEscrow.sol";
import {DemoAsset} from "../contracts/Demo.sol";
import {MockVerifier, MockChainInfo} from "./Mocks.sol";

/// @dev Simulates a real-world smart-contract wallet with no payable receive/fallback
///      (a plain multisig, a misconfigured account contract, etc). It is a normal, honest
///      buyer wallet — not attacker-controlled code, not a hostile asset.
contract NonPayableBuyer { }

/// @notice SC-AUDIT-02 regression. Was Medium: `withdrawBond`'s raw `.call` had no recovery path — if
///         the resolved recipient couldn't accept native value, the bond was permanently stuck, with
///         per-order bookkeeping (`custodyBond`/`bondRecipient`) wedged in an unresolvable state.
///         Fix: `withdrawBond` now only *resolves* (never sends value, so it can never fail on a bad
///         recipient) and credits a pooled `claimableBond[to]`; a separate `claimBond()`, pulled by the
///         recipient itself, does the actual payout. Per-order resolution now always finalizes even when
///         the ultimate payout to a non-payable recipient still can't succeed.
contract ZZBondLockPoCTest is Test {
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
    address CHIP = address(0xC41D);

    PayGoEscrow esc;
    DemoAsset nft;
    uint256 orderId;
    NonPayableBuyer buyer;

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

    function setUp() public {
        vm.etch(VERIFIER, address(new MockVerifier()).code);
        vm.etch(CHAIN_INFO, address(new MockChainInfo()).code);
        nft = new DemoAsset();
        buyer = new NonPayableBuyer();
        address[] memory allowed = new address[](1); allowed[0] = address(nft);
        address[] memory allowedTokens = new address[](1); allowedTokens[0] = USDC;
        esc = new PayGoEscrow(CHAIN_KEY, ROUTER, GRACE, CURE, allowed, CUSTODY_ROUTER, CUSTODY_WINDOW, allowedTokens);
        uint256 tokenId = nft.mint(seller);
        vm.deal(seller, 10 ether);
        vm.startPrank(seller);
        nft.approve(address(esc), tokenId);
        // seller posts a 1 ether custody bond, names `buyer` (an honest, ordinary smart-contract
        // wallet the seller does not control) as the counterparty
        orderId = esc.createOrder{value: 1 ether}(address(buyer), nft, tokenId, PAYEE, USDC, 100e6, 1, 10_000, 1000);
        vm.stopPrank();
        MockChainInfo(CHAIN_INFO).setHeight(9_000);
    }

    function test_withdrawBond_resolvesCleanly_onlyThePullToNonPayableFails() public {
        // Real-world custody fraud: the delivery chip does not match the origin chip.
        // settleCustody correctly slashes the bond to the buyer.
        settleCustodyOne(10_000, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, CHIP, 0, seller), 50);
        address swappedChip = address(0xBAD1D);
        settleCustodyOne(10_001, encodeCustodyTx(CUSTODY_ROUTER, address(esc), orderId, swappedChip, 1, address(buyer)), 51);
        assertTrue(esc.getOrder(orderId).custodyDisputed);
        assertEq(esc.bondRecipient(orderId), address(buyer));
        assertEq(esc.custodyBond(orderId), 1 ether);

        // Resolution now succeeds unconditionally — no external call, can't fail on a bad recipient.
        esc.withdrawBond(orderId);
        assertEq(esc.custodyBond(orderId), 0, "per-order bookkeeping finalized, not wedged");
        assertEq(esc.claimableBond(address(buyer)), 1 ether, "credited to the pooled claimable balance");

        // Only the final pull fails, and only for the non-payable recipient itself — isolated, retryable
        // by anyone in principle, and it doesn't leave any OTHER order's state stuck.
        vm.expectRevert("transfer failed");
        vm.prank(address(buyer));
        esc.claimBond();
        assertEq(esc.claimableBond(address(buyer)), 1 ether, "claim credit untouched, can be pulled once buyer is payable");
        assertEq(address(esc).balance, 1 ether, "still correctly held by the escrow, not lost");
    }
}
