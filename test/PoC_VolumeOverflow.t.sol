// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {INativeQueryVerifier} from "../contracts/Attestcoin.sol";
import {PayGoEscrow} from "../contracts/PayGoEscrow.sol";
import {DemoAsset} from "../contracts/Demo.sol";
import {MockVerifier, MockChainInfo} from "./Mocks.sol";

/// @notice SC-AUDIT-01 regression (was a High: an attacker could permanently brick settle() for an
///         arbitrary victim buyer by pumping CreditPassport.records[victim].volume to uint128's ceiling
///         via a self-minted worthless ERC20, since payToken had no allowlist). Two independent fixes
///         landed: (1) createOrder now requires `allowedPayTokens[payToken]`, closing the free-token
///         enabler; (2) `CreditPassport.Record.volume` is `uint256`, not `uint128`, removing the
///         truncating-cast-then-overflow mechanism even for a legitimately large, allowlisted payment.
///         This test proves both hold.
contract PoC_VolumeOverflow is Test {
    address constant VERIFIER = 0x0000000000000000000000000000000000000FD2;
    address constant CHAIN_INFO = 0x0000000000000000000000000000000000000fD3;
    uint64 constant CHAIN_KEY = 1;
    address constant ROUTER = address(0xA11CE);
    address constant CUSTODY_ROUTER = address(0xC0D1E);
    address constant USDC = address(0xBEEF); // the one allowlisted payToken

    PayGoEscrow esc;
    DemoAsset nft;
    address attacker = address(0xA77ACC);
    address victim = address(0x1C71B);
    address realSeller = address(0x5E11E2);

    function setUp() public {
        vm.etch(VERIFIER, address(new MockVerifier()).code);
        vm.etch(CHAIN_INFO, address(new MockChainInfo()).code);
        nft = new DemoAsset();
        address[] memory allowed = new address[](1); allowed[0] = address(nft);
        address[] memory allowedTokens = new address[](1); allowedTokens[0] = USDC;
        esc = new PayGoEscrow(CHAIN_KEY, ROUTER, 2000, 240, allowed, CUSTODY_ROUTER, 240, allowedTokens);
        MockChainInfo(CHAIN_INFO).setHeight(9_000);
        vm.deal(attacker, 10 ether);
        vm.deal(realSeller, 10 ether);
    }

    function encodeTx(address emitter, address escrow, uint256 id, uint8 no, address payee, address token, uint256 amount)
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
        chunks[2] = abi.encode(uint8(1), uint64(50_000), logs, bytes(""));
        return abi.encode(uint8(2), chunks);
    }

    function settleOne(uint64 height, bytes memory txb, uint64 txIndex) internal {
        uint64[] memory hs = new uint64[](1); hs[0] = height;
        bytes[] memory txs = new bytes[](1); txs[0] = txb;
        INativeQueryVerifier.MerkleProof[] memory ps = new INativeQueryVerifier.MerkleProof[](1);
        ps[0] = INativeQueryVerifier.MerkleProof(bytes32(uint256(txIndex)), new INativeQueryVerifier.MerkleProofEntry[](0));
        esc.settle(hs, txs, ps, INativeQueryVerifier.ContinuityProof(bytes32(0), new bytes32[](0)));
    }

    /// @dev Fix 1: the attacker's self-minted, unlisted ERC20 can no longer even be named as payToken.
    function test_unlistedPayTokenRejectedAtCreateOrder() public {
        address atkToken = address(0xA7CE0);
        uint256 tokenId = nft.mint(attacker);
        vm.startPrank(attacker);
        nft.approve(address(esc), tokenId);
        vm.expectRevert("payToken not allowlisted");
        esc.createOrder{value: 1 wei}(victim, nft, tokenId, address(0xFEED), atkToken, 1, 1, 10_000, 1000);
        vm.stopPrank();
    }

    /// @dev Fix 2: even a legitimate order paid in the one allowlisted token with a very large amount
    ///      no longer overflows `volume` — it's `uint256`, and a subsequent unrelated legitimate
    ///      payment for the same buyer settles normally.
    function test_largeAmountNoLongerOverflowsVolume_andRealPaymentStillSettles() public {
        uint256 tokenId = nft.mint(attacker);
        vm.startPrank(attacker);
        nft.approve(address(esc), tokenId);
        uint256 id1 = esc.createOrder{value: 1 wei}(victim, nft, tokenId, address(0xFEED), USDC, 1, 1, 10_000, 1000);
        vm.stopPrank();
        settleOne(10_000, encodeTx(ROUTER, address(esc), id1, 0, address(0xFEED), USDC, type(uint128).max), 100);

        (, , uint256 volume1) = esc.passport().records(victim);
        assertEq(volume1, type(uint128).max, "large amount recorded exactly, no truncation");

        // A second, unrelated, real order for the same victim still settles fine — no overflow, no brick.
        vm.startPrank(realSeller);
        uint256 realTokenId = nft.mint(realSeller);
        nft.approve(address(esc), realTokenId);
        uint256 realId = esc.createOrder{value: 1 ether}(victim, nft, realTokenId, address(0xFEE), USDC, 100e6, 1, 20_000, 1000);
        vm.stopPrank();
        settleOne(20_000, encodeTx(ROUTER, address(esc), realId, 0, address(0xFEE), USDC, 100e6), 200);   // no revert

        (, , uint256 volumeFinal) = esc.passport().records(victim);
        assertEq(volumeFinal, uint256(type(uint128).max) + 100e6);
        assertTrue(esc.paid(realId, 0), "the previously-bricked-in-theory payment settles normally now");
    }
}
