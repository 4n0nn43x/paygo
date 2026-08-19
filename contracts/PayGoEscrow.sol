// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {INativeQueryVerifier, IChainInfo, VERIFIER, CHAIN_INFO} from "./Attestcoin.sol";

/// @title PayGoEscrow — Creditcoin side of PayGo (hire-purchase, cross-chain, trustless).
/// @notice The asset is escrowed here. Installments are paid in ERC20 on Ethereum through
///         PayGoRouter and only count once proven by Attestcoin. Default is the default state:
///         nobody needs to prove a missing payment — a proof of an on-time payment is what cures.
///         No price oracle, no keeper, no liquidator. Every function is permissionless.
contract PayGoEscrow {
    /// @dev Deadlines are quantized on EPOCH (= precompile MAX_BATCH_RANGE) so payments of
    ///      many orders fall in the same window and settle with ONE continuity proof.
    uint64 public constant EPOCH = 1000;
    bytes32 constant PAID_SIG =
        keccak256("InstallmentPaid(address,uint256,uint8,address,address,address,uint256)");

    enum Status { Active, DefaultAsserted, Defaulted, Completed }

    struct Order {
        address seller;        // Creditcoin: gets the asset back on default
        address buyer;         // Creditcoin: gets the asset on completion
        IERC721 asset;
        uint256 tokenId;
        address payee;         // Ethereum: must receive every installment
        address payToken;      // Ethereum: ERC20 of the installments
        uint64 firstDeadline;  // Ethereum height, % EPOCH == 0
        uint64 interval;       // Ethereum blocks between installments, % EPOCH == 0
        uint8 n;               // number of installments (amounts.length)
        uint8 paidCount;
        uint8 disputedNo;      // installment named by declareDefault
        Status status;
        uint64 assertedAt;     // Creditcoin block of declareDefault
        uint256[] amounts;
    }

    uint64 public immutable CHAIN_KEY;     // Sepolia = 1 on CC3 testnet (NOT the chainId)
    address public immutable ROUTER;       // PayGoRouter on the source chain
    uint64 public immutable GRACE;         // Ethereum blocks after a deadline before default may be asserted
    uint64 public immutable CURE_WINDOW;   // Creditcoin blocks to prove an on-time payment after assertion

    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) internal orders;
    mapping(uint256 => mapping(uint8 => bool)) public paid;
    mapping(bytes32 => bool) public processed;           // nullifier: the protocol has no replay protection
    mapping(address => uint32) public honored;           // passport: installments proven on time
    mapping(address => uint32) public defaulted;         // passport: defaults consumed

    event OrderCreated(uint256 indexed orderId, address indexed seller, address indexed buyer, uint64 firstDeadline, uint64 interval, uint256[] amounts);
    event InstallmentSettled(uint256 indexed orderId, uint8 installmentNo, uint64 sourceHeight);
    event DefaultAsserted(uint256 indexed orderId, uint8 installmentNo, uint64 assertedAt);
    event Cured(uint256 indexed orderId, uint8 installmentNo);
    event Defaulted(uint256 indexed orderId);
    event Completed(uint256 indexed orderId);

    constructor(uint64 chainKey, address router, uint64 grace, uint64 cureWindow) {
        CHAIN_KEY = chainKey;
        ROUTER = router;
        GRACE = grace;
        CURE_WINDOW = cureWindow;
    }

    // ---------------------------------------------------------------- orders

    function createOrder(
        address buyer,
        IERC721 asset,
        uint256 tokenId,
        address payee,
        address payToken,
        uint256[] calldata amounts,
        uint64 firstDeadline,
        uint64 interval
    ) external returns (uint256 id) {
        require(amounts.length > 0 && amounts.length <= 64, "1..64 installments");
        require(firstDeadline % EPOCH == 0 && interval % EPOCH == 0 && interval > 0, "not epoch-aligned");
        id = nextOrderId++;
        Order storage o = orders[id];
        o.seller = msg.sender;
        o.buyer = buyer;
        o.asset = asset;
        o.tokenId = tokenId;
        o.payee = payee;
        o.payToken = payToken;
        o.firstDeadline = firstDeadline;
        o.interval = interval;
        o.n = uint8(amounts.length);
        o.amounts = amounts;
        asset.transferFrom(msg.sender, address(this), tokenId);
        emit OrderCreated(id, msg.sender, buyer, firstDeadline, interval, amounts);
    }

    function getOrder(uint256 id) external view returns (Order memory) { return orders[id]; }

    function deadline(uint256 id, uint8 no) public view returns (uint64) {
        Order storage o = orders[id];
        return o.firstDeadline + uint64(no) * o.interval;
    }

    /// @notice Passport rule, read by the checkout: 4+ honored, 0 defaults → 15% deposit, else 40%.
    function depositBps(address buyer) external view returns (uint16) {
        return (honored[buyer] >= 4 && defaulted[buyer] == 0) ? 1500 : 4000;
    }

    // ---------------------------------------------------------------- settle (= cure)

    /// @notice Settle 1..10 proven Router payments with ONE continuity proof. Anyone may call.
    ///         An on-time payment proven while the order is DefaultAsserted cures it.
    function settle(
        uint64[] calldata heights,
        bytes[] calldata txs,
        INativeQueryVerifier.MerkleProof[] calldata proofs,
        INativeQueryVerifier.ContinuityProof calldata continuity
    ) external {
        uint256 len = heights.length;
        require(len > 0 && len == txs.length && len == proofs.length, "length");
        // 1. nullifier FIRST — the precompile happily verifies the same proof twice
        for (uint256 i; i < len; i++) {
            bytes32 key = keccak256(abi.encodePacked(CHAIN_KEY, heights[i], VERIFIER.calculateTxIndex(proofs[i])));
            require(!processed[key], "replayed");
            processed[key] = true;
        }
        // 2. inclusion + continuity, one call for the whole batch (reverts if invalid)
        require(VERIFIER.verifyAndEmit(CHAIN_KEY, heights, txs, proofs, continuity), "proof");
        // 3-5. receipt status, emitter, fields
        for (uint256 i; i < len; i++) _apply(heights[i], txs[i]);
    }

    function _apply(uint64 height, bytes calldata txBytes) internal {
        EvmV1Decoder.ReceiptFields memory r = EvmV1Decoder.decodeReceiptFields(txBytes);
        require(r.receiptStatus == 1, "tx failed");                       // precompile doesn't check it
        EvmV1Decoder.LogEntry[] memory logs = EvmV1Decoder.getLogsByEventSignature(r, PAID_SIG);
        require(logs.length > 0, "no InstallmentPaid");
        for (uint256 i; i < logs.length; i++) _applyLog(height, logs[i]);
    }

    function _applyLog(uint64 height, EvmV1Decoder.LogEntry memory log) internal {
        require(log.address_ == ROUTER, "wrong emitter");                 // signature filter alone is forgeable
        require(log.topics.length == 3, "topics");
        require(address(uint160(uint256(log.topics[1]))) == address(this), "wrong escrow");
        uint256 id = uint256(log.topics[2]);
        (uint8 no, , address payee, address token, uint256 amount) =
            abi.decode(log.data, (uint8, address, address, address, uint256));

        Order storage o = orders[id];
        require(o.status == Status.Active || o.status == Status.DefaultAsserted, "order closed");
        require(no < o.n && !paid[id][no], "bad installment");
        require(payee == o.payee && token == o.payToken && amount >= o.amounts[no], "payment mismatch");
        require(height <= deadline(id, no), "late payment");              // v1: late never cures

        paid[id][no] = true;
        o.paidCount++;
        honored[o.buyer]++;
        emit InstallmentSettled(id, no, height);

        if (o.status == Status.DefaultAsserted && no == o.disputedNo) {
            o.status = Status.Active;
            emit Cured(id, no);
        }
        if (o.paidCount == o.n) {
            o.status = Status.Completed;
            o.asset.transferFrom(address(this), o.buyer, o.tokenId);
            emit Completed(id);
        }
    }

    // ---------------------------------------------------------------- default (optimistic)

    /// @notice Assert that the earliest unpaid installment is overdue on the attested clock.
    ///         Permissionless, no oracle: the clock is ChainInfo's latest attested height.
    function declareDefault(uint256 id) external {
        Order storage o = orders[id];
        require(o.status == Status.Active, "not active");
        uint8 k;
        while (paid[id][k]) k++;                                          // paidCount < n so this terminates
        IChainInfo.HeightHash memory h = CHAIN_INFO.get_latest_attestation_height_and_hash(CHAIN_KEY);
        require(h.exists && h.height > deadline(id, k) + GRACE, "not overdue");
        o.status = Status.DefaultAsserted;
        o.assertedAt = uint64(block.number);
        o.disputedNo = k;
        emit DefaultAsserted(id, k, o.assertedAt);
    }

    /// @notice Cure window elapsed without a proof → default is consumed, seller takes the asset back
    ///         and keeps every installment already received.
    function finalizeDefault(uint256 id) external {
        Order storage o = orders[id];
        require(o.status == Status.DefaultAsserted, "not asserted");
        require(block.number > o.assertedAt + CURE_WINDOW, "cure window open");
        o.status = Status.Defaulted;
        defaulted[o.buyer]++;
        o.asset.transferFrom(address(this), o.seller, o.tokenId);
        emit Defaulted(id);
    }
}
