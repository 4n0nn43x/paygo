# PayGo — architecture

How the two chains are bound together, why each check exists, and which constraints of the
underlying protocol shaped the design. The README covers what PayGo is and how to run it; this
document covers why it is built the way it is.

## The problem the design answers

The asset lives on Creditcoin. The money lives on Ethereum, because that is where stablecoins and
users actually are. A contract on Creditcoin cannot observe Ethereum, so an escrow there has no way
to know that an installment was paid.

Attestcoin closes that gap with inclusion proofs: a Creditcoin contract can verify that a given
Ethereum transaction exists in a block whose header Creditcoin has attested. That primitive is
*additive only* — it can establish that something happened, never that something did not. There is
no proof of non-inclusion, and no amount of engineering produces one.

Everything below follows from that single constraint.

## Cross-chain settlement

```
Ethereum                                    Creditcoin
PayGoRouter.payInstallment
          / payWithPermit          (EIP-2612)
          / payWithAuthorization   (EIP-3009)
  └─ emit InstallmentPaid(escrow, orderId, no, payer, payee, token, amount)
        │  wait until the source height is attested, then build a batch proof
        ▼
PayGoEscrow.settle(heights[], txs[], merkleProofs[], sharedContinuityProof)
  1. nullifier  keccak(chainKey‖height‖calculateTxIndex(proof))   — set BEFORE anything else
  2. VERIFIER(0x…0FD2).verifyAndEmit(batch)                        — one call, ≤10 txs, ≤1000 blocks
  3. EvmV1Decoder.decodeReceiptFields → receiptStatus == 1
  4. getLogsByEventSignature → log.address_ == ROUTER && topics[1] == address(this)
  5. order open, installment unpaid, payee/token match, amount ≥ due, height ≤ deadline
  → mark paid, record to passport, cure if DefaultAsserted, complete if last

PayGoEscrow.declareDefault(id)
  CHAIN_INFO(0x…0fD3).get_latest_attestation_height_and_hash(chainKey).height > deadline + GRACE

PayGoEscrow.finalizeDefault(id)
  block.number > assertedAt + CURE_WINDOW  → Defaulted, asset returns to the seller
```

### Why each check exists

These are not defensive boilerplate. Each corresponds to a property of the precompile verified
empirically before the contracts were written:

- **The precompile has no replay protection.** The same proof verifies twice, happily. The nullifier
  is therefore written *before* any other work, and derived from `(chainKey, height, txIndex)` so it
  is unforgeable and fixed-size. A `salt` domain-separates the payment and custody namespaces so the
  same source transaction can never collide across the two proof kinds.
- **`verifyAndEmit` reverts on an invalid proof and never returns false.** A `try/catch` would be
  required for any non-reverting failure branch; there is none, so proof integrity is a hard revert
  in `settle`, before a single log is examined.
- **The precompile does not check `receiptStatus`.** A failed transaction is perfectly provable.
  Without this check, a reverted payment would settle an installment.
- **Log lookup filters on the event signature alone.** Any contract can emit an event with the same
  signature, so the emitter must be pinned to the known Router, and `topics[1]` to this escrow
  instance — that second check is what namespaces orders per deployment.

### Filters, not assertions

A batch may carry logs from many unrelated orders, and the nullifier is one key per source
transaction. If a single non-applicable log reverted the batch, a griefer could co-locate a bad log
with a victim's payment and make that payment permanently unsettleable — and, through the cure path,
force a wrongful default.

So checks 3 to 5 skip a non-applicable log and let the rest settle. Only checks 1 and 2 revert.

## The two clocks

| Clock | Measures | Used for |
|---|---|---|
| Ethereum block height | the only timestamp an inclusion proof carries (`headerNumber`; the header's timestamp is not provable) | payment deadlines |
| Creditcoin block number | local contract time | the cure window — time to *submit* a proof |

Keeping these separate is what makes the protocol fair under latency. A payment made at a height at
or below its deadline is valid no matter when its proof arrives, so "paid 30 seconds before the
deadline, attested 10 minutes after" is not a failure case — it does not exist. The cure window is
sized at least twice the observed attestation latency.

## Batching

`EPOCH = 1000` blocks is the precompile's `MAX_BATCH_RANGE`: one continuity proof can span at most
that many source blocks. Every PayGo deadline is therefore quantised onto that grid —
`firstDeadline % EPOCH == 0` and `interval % EPOCH == 0` — so payments belonging to *different*
orders land in the same window and can be proven together.

`settle` accepts 1 to 10 proofs with a single shared continuity proof. Whoever submits pays less per
installment than they would one by one, which is the incentive: no keeper has to be paid to do it.

Measured effect, with transaction links, in the README. Batching roughly halves per-installment cost;
proof freshness is worth about a factor of two on the verification itself and is the secondary lever.

## Default as the default state

Since absence cannot be proven, the protocol never asks anyone to prove a missed payment.

```
Active ──all installments proven──▶ Completed ──▶ claimAsset (buyer)
  │  ▲
  │  └── settle of an on-time payment (implicit cure)
  ▼
DefaultAsserted ──cure window elapsed──▶ Defaulted ──▶ withdrawAsset (seller)
```

`declareDefault` is an optimistic assertion, permissionless and oracle-free: it reads the latest
attested Ethereum height from the ChainInfo precompile and compares it against `deadline + GRACE`.
A proof of an on-time payment is its fraud proof. The lineage is familiar — optimistic assertions
with challenge windows, and grace periods in conventional lending.

Three consequences:

1. **`DefaultAsserted` must exist as a distinct state.** Without it the seller could withdraw and
   resell during the grace period, and a valid cure would arrive with nothing left to cure.
2. **A late payment does not cure.** Cure-with-penalty is a product decision, not a protocol change.
3. **A consumed default follows hire-purchase convention:** the seller recovers the asset and keeps
   the installments already received.

There is no `Created` state. `Active` is the zero value of the enum and an order is active from
`createOrder` — the deposit is not an entry condition, which removes a passport-poisoning path.

## Pull, never push

`settle` never transfers the ERC-721, and `finalizeDefault` never transfers it either. Both only set
state; the recipient calls `claimAsset` or `withdrawAsset` afterwards. Custody bonds work the same
way: `withdrawBond` resolves the bookkeeping with no external call, and `claimBond` performs the
actual, retryable transfer to `msg.sender`.

The reason is batch isolation. A seller-supplied ERC-721 whose `transferFrom` reverts on the release
leg would otherwise roll back the entire transaction — including every *other* order's proof settled
in the same batch, whose nullifiers are already consumed. Pull-based release confines the damage to
the claim that is actually broken.

## Payment paths

`PayGoRouter` is stateless and has no admin. Three ways in, one event out:

- `payInstallment` — plain `transferFrom` after an approval.
- `payWithPermit` — EIP-2612, one transaction instead of approve-then-pay.
- `payWithAuthorization` — EIP-3009. The buyer pre-signs the remaining installments at checkout with
  staggered validity windows; anyone may submit them when they come due.

`receiveWithAuthorization` is used rather than `transferWithAuthorization`, per the EIP's own
recommendation for contract calls: only the Router can consume the buyer's signature, so autopay
cannot be front-run to a different payee. The authorization nonce is not free — it is
`keccak256(escrow, orderId, installmentNo, payee)`, recomputed by the Router from its arguments.
Change the payee and the signature no longer recovers the buyer. Consent commits to where the money
goes.

A bare ERC-20 transfer without a Router was considered and rejected: there is no memo field to bind
`(orderId, installmentNo)`, and proving against a shared `Transfer` event signature is explicitly
discouraged.

## Passports

`CreditPassport` and `SellerPassport` are ERC-5192 soulbound records. They hold facts, not a score:
installments honored, defaults, cumulative volume; deliveries confirmed, mismatches proven.

The escrow both writes and reads them. `createOrder` calls `depositBps(buyer)` — 40 % for a
newcomer, 15 % after four honored installments with no default — and `waivesBond(seller)` decides
whether a custody stake is required. Every entry is the by-product of a verified inclusion proof, so
the record cannot be self-reported.

The volume accumulator saturates rather than overflowing: a buyer whose cumulative volume would wrap
must never become unable to transact.

## Proof-of-Custody

An inclusion proof establishes who paid. It says nothing about whether the physical object behind a
tokenised asset is the one that was listed — the gap every real-world-asset design has to face.

PayGo binds an EIP-5791 style chip (a self-generated secp256k1 keypair embedded in the object) to the
order. The chip signs a challenge at listing (`role = Origin`, submitted by the seller) and again at
handoff (`role = Delivery`, submitted by the buyer). Both attestations travel through `CustodyRouter`
on Ethereum and reach `settleCustody` under the same five checks as payments.

The asymmetry is deliberate:

- **A match is positive evidence.** Only the genuine chip can produce it. The bond returns to the
  seller and `SellerPassport` records a confirmed delivery.
- **A mismatch is not the mirror image.** A chip is just a keypair, so anyone can sign with a key
  they generated. A mismatch proves only that *some other key* signed — never that the object was
  swapped. Paying the buyer for one would be a bounty on lying. The bond is therefore burned: a
  seller who genuinely swapped the item still loses it, and a buyer gains nothing by claiming a swap.

Once again, only positive facts are ever proven.

The bond is a flat stake in native CTC, chosen by the seller, never a fraction of `price`. `price` is
denominated in the Ethereum-side payment token, so indexing the bond to it would require a
CTC/token oracle — reintroducing exactly the dependency the payment side avoids. The oracle-free rule
is instead reputational: a seller with no clean delivery record must post something; four
chip-matched deliveries with no proven mismatch waive it.

If neither party ever scans, the bond reverts to the seller after `CUSTODY_WINDOW` blocks past order
closure. Silence is not evidence against the seller — the same polarity as the payment side.

## Design constraints and accepted limits

1. **No return path to Ethereum.** Cross-chain writability is not available, so the asset lives on
   Creditcoin by design. This is a design decision, not a workaround: nothing in the protocol needs
   to send a message back.
2. **The relayer is a convenience.** `settle`, `settleCustody`, `declareDefault`, `finalizeDefault`
   and autopay submission are all permissionless. A buyer who does not trust the relayer can always
   submit the same proof and save themselves.
3. **The seller carries the asset risk.** There is no lender pool.
4. **A late payment never cures.**
5. **The passport is a discount, not a boundary.** Two cooperating wallets can manufacture history by
   completing real orders between themselves. The cost is raised, not eliminated; permissionless
   reputation without identity cannot do better. The asset stays escrowed and reverts to the seller
   on default regardless of the buyer's record.
6. **Proof-of-Custody detects substitution, not fabrication.** A seller can attest both roles on a
   sham order with a throwaway chip. The mechanism proves that the object delivered is the object
   listed; it cannot prove a chip was ever attached to a real object.
7. **Schedule bounds.** 1 to 64 installments, `price >= n`, and the full schedule
   (`firstDeadline + n × interval + GRACE`) must fit in `uint64` — an unbounded schedule would panic
   inside the filter chain and reopen the poison-log path.

## Environment

Solidity 0.8.30, optimizer at 200 runs, `evm_version = "shanghai"`.
`@gluwa/usc-sdk@0.18.0`, `@gluwa/usc-contracts@0.1.2`.
`EvmV1Decoder` is an external library, linked at deploy time; on CC3 testnet it is deployed at
`0x731c345d79Fb8BbDC541f9DF3b6317585F849F9f`.

`chainKey` is Attestcoin's identifier for the source chain and is **not** an EVM chain id — Sepolia
is `1` on CC3 testnet, and the mapping differs per environment. It is a constant per deployment,
never a user-supplied parameter.

Security reviews, findings and accepted residuals: [`AUDIT.md`](AUDIT.md).
