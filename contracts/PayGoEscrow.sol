// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";
import {INativeQueryVerifier, IChainInfo, VERIFIER, CHAIN_INFO} from "./Attestcoin.sol";
import {CreditPassport} from "./CreditPassport.sol";
import {SellerPassport} from "./SellerPassport.sol";

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
    bytes32 constant CUSTODY_SIG =
        keccak256("PossessionAttested(address,uint256,address,uint8,address)");
    /// @dev A mismatched Delivery scan resolves the bond here, where nobody can ever pull it (`claimBond`
    ///      pays `msg.sender`). Paying it to the buyer would put a bounty on lying: a "chip" is just a
    ///      keypair, so any buyer can generate one and manufacture a mismatch for free. Only a MATCH is a
    ///      positive proof; a non-match proves only that someone signed with some other key. Burning keeps
    ///      the deterrent against a seller who really swapped the item while removing the buyer's profit
    ///      motive. Residual: a buyer can still destroy the bond and brand the seller for one Sepolia tx,
    ///      with nothing to gain — griefing, not theft. See docs/AUDIT.md SC-AUDIT-04.
    address constant BURN = 0x000000000000000000000000000000000000dEaD;

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
        uint64 closedAt;       // Creditcoin block the order closed (Completed or Defaulted): starts the custody dispute window
        address chipId;        // Proof-of-Custody: the chip bound at the Origin attestation (0 = unbound)
        bool custodyVerified;  // Delivery chip matched the Origin chip
        bool custodyDisputed;  // Delivery chip did NOT match — cryptographic proof of substitution
        uint256[] amounts;
    }

    uint64 public immutable CHAIN_KEY;     // Sepolia = 1 on CC3 testnet (NOT the chainId)
    address public immutable ROUTER;       // PayGoRouter on the source chain
    address public immutable CUSTODY_ROUTER; // CustodyRouter on the source chain (Proof-of-Custody)
    uint64 public immutable GRACE;         // Ethereum blocks after a deadline before default may be asserted
    uint64 public immutable CURE_WINDOW;   // Creditcoin blocks to prove an on-time payment after assertion
    uint64 public immutable CUSTODY_WINDOW; // Creditcoin blocks after the order closed (Completed or Defaulted) before an unresolved bond reverts to the seller

    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) internal orders;
    mapping(uint256 => mapping(uint8 => bool)) public paid;
    mapping(bytes32 => bool) public processed;           // nullifier: the protocol has no replay protection
    mapping(address => bool) public allowedAssets;        // vetted ERC-721 contracts only — no arbitrary seller code
    mapping(address => bool) public allowedPayTokens;      // vetted ERC-20 payTokens only — same reasoning as allowedAssets
    mapping(uint256 => uint256) public custodyBond;       // native CTC staked by the seller at createOrder
    mapping(uint256 => address) public bondRecipient;     // set once resolved; withdrawBond credits this address
    mapping(uint256 => bool) public released;             // SC-AUDIT-05: the asset leg of an order pays out ONCE
    mapping(address => uint256) public claimableBond;      // pooled, pulled by claimBond — SC-AUDIT-02
    CreditPassport public immutable passport;            // soulbound facts, written here, read by createOrder
    SellerPassport public immutable sellerPassport;       // soulbound custody facts, read by createOrder

    event OrderCreated(uint256 indexed orderId, address indexed seller, address indexed buyer, uint64 firstDeadline, uint64 interval, uint256[] amounts);
    event InstallmentSettled(uint256 indexed orderId, uint8 installmentNo, uint64 sourceHeight);
    event DefaultAsserted(uint256 indexed orderId, uint8 installmentNo, uint64 assertedAt);
    event Cured(uint256 indexed orderId, uint8 installmentNo);
    event Defaulted(uint256 indexed orderId);
    event Completed(uint256 indexed orderId);
    event AssetClaimed(uint256 indexed orderId, address indexed buyer);
    event AssetWithdrawn(uint256 indexed orderId, address indexed seller);
    event CustodyOriginBound(uint256 indexed orderId, address indexed chip, uint64 height);
    event AuthenticityConfirmed(uint256 indexed orderId, address indexed chip, uint64 height);
    event AuthenticityDisputed(uint256 indexed orderId, address originChip, address deliveryChip, uint64 height);
    event BondWithdrawn(uint256 indexed orderId, address indexed to, uint256 amount);

    /// @dev `allowedAssets_` is fixed at deploy time — no admin, no add/remove function, matching the
    ///      rest of the protocol (zero governance). A seller-supplied ERC-721 whose `transferFrom` is
    ///      coded to revert on the release leg can no longer be listed at all, since only vetted asset
    ///      contracts are eligible. ponytail: allowlisting a new asset type means a new escrow deployment
    ///      (fine for an MVP with few asset contracts); upgrade path if that's too rigid is a permissionless
    ///      `registerAsset` gated on a bytecode-hash allowlist instead of a fixed constructor list.
    constructor(
        uint64 chainKey, address router, uint64 grace, uint64 cureWindow, address[] memory allowedAssets_,
        address custodyRouter, uint64 custodyWindow, address[] memory allowedPayTokens_
    ) {
        CHAIN_KEY = chainKey;
        ROUTER = router;
        CUSTODY_ROUTER = custodyRouter;
        GRACE = grace;
        CURE_WINDOW = cureWindow;
        CUSTODY_WINDOW = custodyWindow;
        passport = new CreditPassport(address(this));
        sellerPassport = new SellerPassport(address(this));
        for (uint256 i; i < allowedAssets_.length; i++) allowedAssets[allowedAssets_[i]] = true;
        for (uint256 i; i < allowedPayTokens_.length; i++) allowedPayTokens[allowedPayTokens_[i]] = true;
    }

    // ---------------------------------------------------------------- orders

    /// @notice Seller escrows the asset and names the price; PayGo sizes the deposit from the buyer's
    ///         passport (40% for a newcomer, 15% after 4 honored installments and no default) and
    ///         splits the remainder evenly over the other installments.
    /// @dev `msg.value` is an optional custody bond (native CTC), slashed to the buyer if a later
    ///      Proof-of-Custody delivery scan proves the chip was swapped (see `settleCustody`). Deliberately
    ///      NOT sized as a fraction of `price`: `price` is denominated in the Ethereum-side payToken and
    ///      there is no CTC/payToken price oracle — introducing one here would smuggle back the exact
    ///      oracle dependency PayGo avoids on the payment side. So the rule is oracle-free: a newcomer
    ///      seller (no clean custody track record) must post *some* bond; 4+ chip-matched deliveries and
    ///      never a proven mismatch waives it. The bond amount itself stays entirely the seller's call.
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
    ) external payable returns (uint256 id) {
        require(n > 0 && n <= 64 && price >= n, "1..64 installments, price >= n");
        require(firstDeadline % EPOCH == 0 && interval % EPOCH == 0 && interval > 0, "not epoch-aligned");
        // SC-AUDIT-06: `deadline()` is checked uint64 arithmetic reached from inside `_applyLog`'s filter
        // chain. An unbounded schedule would make it PANIC there instead of returning — turning a
        // non-applicable log back into a batch-reverting poison log (the very thing MEDIUM-1 fixed) and
        // leaving the order exitless, since `declareDefault` computes the same expression.
        require(uint256(firstDeadline) + uint256(n) * uint256(interval) + uint256(GRACE) <= type(uint64).max,
            "schedule overflows uint64");
        require(buyer != msg.sender && buyer != address(0), "no self-dealing");   // trivial passport-sybil gate
        require(allowedAssets[address(asset)], "asset not allowlisted");
        require(allowedPayTokens[payToken], "payToken not allowlisted");   // SC-AUDIT-01: was the enabler for a fake-token DoS
        require(msg.value > 0 || sellerPassport.waivesBond(msg.sender), "post a custody bond, or build a clean delivery record");
        id = nextOrderId++;
        custodyBond[id] = msg.value;
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
        _verifyBatch(heights, txs, proofs, continuity, "");
        // 3-5. receipt status, emitter, fields
        for (uint256 i; i < heights.length; i++) _apply(heights[i], txs[i]);
    }

    /// @dev Checks 1-2, shared by `settle` and `settleCustody`. `salt` domain-separates the nullifier
    ///      namespaces ("" for payments, "custody" for chip attestations) so the same (height, txIndex)
    ///      pair can never collide across the two proof kinds, even if a future tx carried both event types.
    function _verifyBatch(
        uint64[] calldata heights,
        bytes[] calldata txs,
        INativeQueryVerifier.MerkleProof[] calldata proofs,
        INativeQueryVerifier.ContinuityProof calldata continuity,
        bytes memory salt
    ) internal {
        uint256 len = heights.length;
        require(len > 0 && len == txs.length && len == proofs.length, "length");
        // 1. nullifier FIRST — the precompile happily verifies the same proof twice
        for (uint256 i; i < len; i++) {
            bytes32 key = keccak256(abi.encodePacked(CHAIN_KEY, heights[i], VERIFIER.calculateTxIndex(proofs[i]), salt));
            require(!processed[key], "replayed");
            processed[key] = true;
        }
        // 2. inclusion + continuity, one call for the whole batch (reverts if invalid)
        require(VERIFIER.verifyAndEmit(CHAIN_KEY, heights, txs, proofs, continuity), "proof");
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
            o.status = Status.Completed;               // asset released via claimAsset, not pushed here —
            o.closedAt = uint64(block.number);          // a hostile transferFrom must not brick this shared batch
            emit Completed(id);
        }
    }

    // ---------------------------------------------------------------- Proof-of-Custody (settle = same 5 checks)

    /// @notice Settle 1..10 proven chip attestations from CustodyRouter with ONE continuity proof.
    ///         Anyone may call — the buyer's own delivery scan submission is what protects them.
    function settleCustody(
        uint64[] calldata heights,
        bytes[] calldata txs,
        INativeQueryVerifier.MerkleProof[] calldata proofs,
        INativeQueryVerifier.ContinuityProof calldata continuity
    ) external {
        _verifyBatch(heights, txs, proofs, continuity, "custody");
        for (uint256 i; i < heights.length; i++) _applyCustody(heights[i], txs[i]);
    }

    function _applyCustody(uint64 height, bytes calldata txBytes) internal {
        EvmV1Decoder.ReceiptFields memory r = EvmV1Decoder.decodeReceiptFields(txBytes);
        if (r.receiptStatus != 1) return;
        EvmV1Decoder.LogEntry[] memory logs = EvmV1Decoder.getLogsByEventSignature(r, CUSTODY_SIG);
        for (uint256 i; i < logs.length; i++) _applyCustodyLog(height, logs[i]);
    }

    /// @dev role 0 = Origin (binds the order's chip, first attestation wins); role 1 = Delivery (compares
    ///      against the bound chip). A MATCH is a positive proof — only the genuine chip can produce it —
    ///      and releases the bond to the seller. A mismatch is NOT the mirror image: any buyer can sign with
    ///      a key they generated, so it proves nothing about the item and pays nobody (see `BURN`).
    ///      SC-AUDIT-03 (Variant A): `submitter` is CustodyRouter's real, unspoofable `msg.sender` — it
    ///      MUST be checked against `o.seller`/`o.buyer`, or any third party can squat the Origin slot
    ///      with a throwaway chip before the real seller's real chip ever attests, later causing an
    ///      honest seller's bond to be wrongly slashed on the buyer's genuine delivery scan. This closes
    ///      that variant; it does NOT close a seller who legitimately self-forges both roles on their own
    ///      sham order with a throwaway chip (Variant B — a design-level residual, not a code bug; see
    ///      docs/08-proof-of-custody.md and docs/AUDIT.md).
    function _applyCustodyLog(uint64 height, EvmV1Decoder.LogEntry memory log) internal {
        if (log.address_ != CUSTODY_ROUTER) return;
        if (log.topics.length != 3) return;
        if (address(uint160(uint256(log.topics[1]))) != address(this)) return;
        uint256 id = uint256(log.topics[2]);
        (address chip, uint8 role, address submitter) = abi.decode(log.data, (address, uint8, address));

        Order storage o = orders[id];
        if (o.seller == address(0)) return;                              // unknown order
        if (o.custodyVerified || o.custodyDisputed) return;               // one resolution per order

        if (role == 0) {
            if (submitter != o.seller) return;                           // only the seller may bind Origin
            if (o.chipId != address(0)) return;                          // already bound — first wins
            o.chipId = chip;
            emit CustodyOriginBound(id, chip, height);
        } else {
            if (submitter != o.buyer) return;                            // only the buyer may attest Delivery
            if (o.chipId == address(0)) return;                          // nothing to compare against yet
            if (chip == o.chipId) {
                o.custodyVerified = true;
                bondRecipient[id] = o.seller;
                sellerPassport.record(o.seller, true);
                emit AuthenticityConfirmed(id, chip, height);
            } else {
                o.custodyDisputed = true;
                bondRecipient[id] = BURN;                  // SC-AUDIT-04: a mismatch is not evidence — nobody is paid
                sellerPassport.record(o.seller, false);
                emit AuthenticityDisputed(id, o.chipId, chip, height);
            }
        }
    }

    /// @notice Resolve the custody bond once eligible: `settleCustody` set the recipient on a chip match
    ///         or mismatch, or — absent either, past the window after the order closed (Completed or
    ///         Defaulted) — the presumption favors the seller (Attestcoin can prove a swap happened; it can
    ///         never prove one didn't, so silence is not evidence against the seller, exactly the polarity
    ///         the payment side already uses). A Defaulted order must time out too, or a buyer who never
    ///         pays and never scans would strand the seller's bond forever.
    /// @dev SC-AUDIT-02: this used to pay out directly via a raw `.call`, which permanently stranded the
    ///      bond (per-order, unretriable) if the resolved recipient could never accept a bare transfer.
    ///      Split into resolve (here — no external call, can never fail on a bad recipient) and pull
    ///      (`claimBond`, below) so per-order bookkeeping always finalizes and the payout itself is a
    ///      retryable, pooled, recipient-initiated pull — the same discipline `claimAsset`/`withdrawAsset`
    ///      already use for the ERC-721 leg.
    function withdrawBond(uint256 id) external {
        Order storage o = orders[id];
        address to = bondRecipient[id];
        if (to == address(0) && (o.status == Status.Completed || o.status == Status.Defaulted) && !o.custodyDisputed
            && o.closedAt != 0 && block.number > o.closedAt + CUSTODY_WINDOW) {
            to = o.seller;
        }
        require(to != address(0), "not resolved");
        uint256 amount = custodyBond[id];
        require(amount > 0, "no bond");
        custodyBond[id] = 0;
        bondRecipient[id] = to;
        claimableBond[to] += amount;
        emit BondWithdrawn(id, to, amount);
    }

    /// @notice Pull whatever custody bonds have resolved to `msg.sender`, across every order. Permissionless
    ///         (anyone may call `withdrawBond` to credit a recipient; only the recipient itself can pull).
    function claimBond() external {
        uint256 amount = claimableBond[msg.sender];
        require(amount > 0, "nothing claimable");
        claimableBond[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
    }

    // ---------------------------------------------------------------- default (optimistic)

    /// @notice Assert that the earliest unpaid installment is overdue on the attested clock.
    ///         Permissionless, no oracle: the clock is ChainInfo's latest attested height.
    function declareDefault(uint256 id) external {
        Order storage o = orders[id];
        // SC-AUDIT-07: an unwritten order reads status Active (enum 0) with deadline 0, so without this the
        // id of a FUTURE order can be pushed to Defaulted before it exists — `createOrder` never resets the
        // lifecycle fields, so the order would be born closed. Mirrors `_applyCustodyLog`'s existence check.
        require(o.seller != address(0), "unknown order");
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
        o.status = Status.Defaulted;                    // asset released via withdrawAsset, not pushed here
        o.closedAt = uint64(block.number);              // starts the custody window: an unresolved bond returns to the seller
        passport.record(o.buyer, false, 0);
        emit Defaulted(id);
    }

    // ---------------------------------------------------------------- asset release (pull, not push)

    /// @notice Buyer collects the asset after Completed. A separate call, isolated from `settle`: if the
    ///         seller's ERC-721 is buggy or hostile and its `transferFrom` reverts, only this claim fails —
    ///         it can no longer brick the settle batch that also carried other orders' proofs.
    function claimAsset(uint256 id) external {
        Order storage o = orders[id];
        require(o.status == Status.Completed, "not completed");
        require(!released[id], "already released");   // SC-AUDIT-05: terminal status is absorbing, so without
        released[id] = true;                          // this the call replays once the token is re-escrowed
        o.asset.transferFrom(address(this), o.buyer, o.tokenId);
        emit AssetClaimed(id, o.buyer);
    }

    /// @notice Seller collects the asset back after Defaulted. Same isolation as `claimAsset`.
    function withdrawAsset(uint256 id) external {
        Order storage o = orders[id];
        require(o.status == Status.Defaulted, "not defaulted");
        require(!released[id], "already released");   // SC-AUDIT-05, seller leg — same replay, same fix
        released[id] = true;
        o.asset.transferFrom(address(this), o.seller, o.tokenId);
        emit AssetWithdrawn(id, o.seller);
    }
}
