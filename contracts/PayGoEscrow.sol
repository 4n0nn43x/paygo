// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {INativeQueryVerifier, IChainInfo, VERIFIER, CHAIN_INFO} from "./Attestcoin.sol";
import {CreditPassport} from "./CreditPassport.sol";

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
    CreditPassport public immutable passport;            // soulbound facts, written here, read by createOrder

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
        passport = new CreditPassport(address(this));
    }

    // ---------------------------------------------------------------- orders

    /// @notice Seller escrows the asset and names the price; PayGo sizes the deposit from the buyer's
    ///         passport (40% for a newcomer, 15% after 4 honored installments and no default) and
    ///         splits the remainder evenly over the other installments.
    function createOrder(
        address buyer,
        IERC721 asset,
        uint256 tokenId,
        address payee,
        address payToken,
        uint256 price,
        uint8 n,
        uint64 firstDeadline,
        uint64 interval
    ) external returns (uint256 id) {
        require(n > 0 && n <= 64 && price >= n, "1..64 installments, price >= n");
        require(firstDeadline % EPOCH == 0 && interval % EPOCH == 0 && interval > 0, "not epoch-aligned");
        require(buyer != msg.sender && buyer != address(0), "no self-dealing");   // trivial passport-sybil gate
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
        o.n = n;
        uint256[] memory amounts = new uint256[](n);
        if (n == 1) amounts[0] = price;
        else {
            uint256 deposit = price * passport.depositBps(buyer) / 10_000;
            uint256 each = (price - deposit) / (n - 1);
            require(each > 0, "price too small for n installments");
            amounts[0] = deposit;
            for (uint8 i = 1; i < n; i++) amounts[i] = each;
            amounts[n - 1] += (price - deposit) - each * (n - 1);   // dust to the last one
        }
        o.amounts = amounts;
        asset.transferFrom(msg.sender, address(this), tokenId);
        emit OrderCreated(id, msg.sender, buyer, firstDeadline, interval, amounts);
    }

    function getOrder(uint256 id) external view returns (Order memory) { return orders[id]; }

    function deadline(uint256 id, uint8 no) public view returns (uint64) {
        Order storage o = orders[id];
        return o.firstDeadline + uint64(no) * o.interval;
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

    /// @dev A settled batch may bundle txs/logs from many orders; a single non-applicable log must not
    ///      revert the batch, or a griefer could co-locate a bad log with a victim's payment and brick
    ///      it forever (the nullifier is per-tx). So the 5 checks are FILTERS here: a log that fails any
    ///      of them is skipped, and the applicable logs still settle. Proof integrity (nullifier +
    ///      verifyAndEmit) is enforced in `settle` before we ever get here and stays a hard revert.
    function _apply(uint64 height, bytes calldata txBytes) internal {
        EvmV1Decoder.ReceiptFields memory r = EvmV1Decoder.decodeReceiptFields(txBytes);
        if (r.receiptStatus != 1) return;                                 // precompile doesn't check it; failed tx → nothing to apply
        EvmV1Decoder.LogEntry[] memory logs = EvmV1Decoder.getLogsByEventSignature(r, PAID_SIG);
        for (uint256 i; i < logs.length; i++) _applyLog(height, logs[i]);
    }

    function _applyLog(uint64 height, EvmV1Decoder.LogEntry memory log) internal {
        if (log.address_ != ROUTER) return;                              // signature filter alone is forgeable
        if (log.topics.length != 3) return;
        if (address(uint160(uint256(log.topics[1]))) != address(this)) return;   // for a different escrow deployment
        uint256 id = uint256(log.topics[2]);
        (uint8 no, , address payee, address token, uint256 amount) =
            abi.decode(log.data, (uint8, address, address, address, uint256));

        Order storage o = orders[id];
        if (!(o.status == Status.Active || o.status == Status.DefaultAsserted)) return;   // closed order
        if (no >= o.n || paid[id][no]) return;                           // unknown/already-paid installment
        if (payee != o.payee || token != o.payToken || amount < o.amounts[no]) return;    // payment mismatch
        if (height > deadline(id, no)) return;                           // v1: late never cures

        paid[id][no] = true;
        o.paidCount++;
        passport.record(o.buyer, true, amount);
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
        passport.record(o.buyer, false, 0);
        o.asset.transferFrom(address(this), o.seller, o.tokenId);
        emit Defaulted(id);
    }
}
