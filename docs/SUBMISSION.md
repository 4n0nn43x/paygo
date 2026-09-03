# PayGo — technical submission (BUIDL CTC 2026 Fall)

**Track**: RWA / DeFi (label only — top-3 overall). **Repo**: this one. **Demo**: see `DEMO.md`, video linked in the DoraHacks entry.

## What it is
Hire-purchase (BNPL for assets) across chains, without a trusted party.
The asset (ERC-721) is escrowed in `PayGoEscrow` on **Creditcoin**. The buyer pays installments in ERC20
on **Ethereum** through `PayGoRouter`. An installment only exists for the escrow once its Ethereum
transaction is **proven by Attestcoin**. Last proof → asset released to the buyer. Silence after the
grace period → default, asserted by anyone against the attested clock; a proof of an on-time payment
cures it. Every accepted proof is written to an ERC-5192 **credit passport** that the escrow reads back
to size the next deposit.

No price oracle (fixed schedule, the asset is the collateral). No keeper (the unhappy path costs no gas
until someone wants the asset back). No liquidator. Every function is permissionless.

## Attestcoin integration (the full cycle, executed on testnet)

```
Sepolia                                  Creditcoin CC3
PayGoRouter.payInstallment / payWithPermit / payWithAuthorization
  └─ emit InstallmentPaid(escrow, orderId, no, payer, payee, token, amount)
        │  worker: waitUntilHeightAttested → ProofBuilder.getBatchProof([tx…])
        ▼
PayGoEscrow.settle(heights[], txs[], merkleProofs[], sharedContinuityProof)
  1. nullifier  keccak(chainKey‖height‖calculateTxIndex(proof))  — set BEFORE anything else
  2. VERIFIER(0x…0FD2).verifyAndEmit(batch)                        — one call, ≤10 txs, ≤1000 blocks
  3. EvmV1Decoder.decodeReceiptFields → require receiptStatus == 1
  4. getLogsByEventSignature → require log.address_ == ROUTER && topics[1] == address(this)
  5. decode fields → order open, installment unpaid, payee/token match, amount ≥ due, height ≤ deadline
  → paid, passport.record, cure if DefaultAsserted, release asset if last
PayGoEscrow.declareDefault(id)  CHAIN_INFO(0x…0fD3).get_latest_attestation_height_and_hash(chainKey).height > deadline + GRACE
PayGoEscrow.finalizeDefault(id) block.number > assertedAt + CURE_WINDOW  → asset to seller, passport.record(default)
```

Why each check exists (verified empirically against the precompile, 17-19 Aug): the precompile has no
replay protection (the same proof verifies twice), does not check `receiptStatus` (a failed tx is
provable), and `getLogsByEventSignature` filters on the signature only (any contract can emit
`InstallmentPaid`). The two clocks are deliberate: deadlines are **Ethereum heights** (the only
provable timestamp — the proof carries `headerNumber`), the cure window is **Creditcoin blocks**
(time to *submit* a proof, ≥ 2× attestation latency).

### Deadline quantization → batch
All deadlines are `firstDeadline + k·interval` with both multiples of `EPOCH = 1000` = the precompile's
`MAX_BATCH_RANGE`. Payments of *different* orders in the same window share one continuity proof.
`settle` takes arrays; the worker fills a batch per window. Measured: −51 % gas per installment with 3.

### Design choices forced by the protocol
- Attestcoin proves inclusion, never absence → **default is the default state**, the proof is the
  optimistic assertion's fraud proof (UMA / rollup challenge windows / TradFi grace periods).
- No writability on testnet → the asset lives on Creditcoin by design; no message back to Ethereum is
  needed. Stated as a choice, not a workaround.
- `receiveWithAuthorization` (EIP-3009), not `transferWith…`: only the Router can consume the buyer's
  pre-signed authorizations, so autopay cannot be front-run to another payee.

## Measured (CC3 testnet, see README for tx links)
| scenario | gas |
|---|---|
| 1 fresh proof, full settle | 357 476 |
| 3 proofs, 1 continuity proof | 528 416 → 176 139 each (−51 %) |
| precompile `verify` fresh / +6 h / +24 h / +7 d | 43 748 / 85 665 / 84 284 / 86 127 (×2, then flat) |

## Proof-of-Custody: the real↔tokenized link (new)
Attestcoin proves *who paid*, never *what the token represents*. Proof-of-Custody closes that gap the
same way the payment side works: two positive proofs, no jury for the common case. A chip embedded in
the physical asset (EIP-5791 "Physical Backed Token" pattern — a self-generated secp256k1 keypair)
signs a challenge at listing (`role=Origin`) and again at handoff (`role=Delivery`), both proven
cross-chain through the identical `settle`-style pipeline (nullifier, `verifyAndEmit`, receiptStatus,
emitter filter, fields) via a new `CustodyRouter.sol` on Sepolia and `PayGoEscrow.settleCustody`. Same
chip both times = cryptographic proof of no substitution, and the bond returns to the seller. A mismatch is
deliberately **not** its mirror image: a chip is a keypair, so anyone can produce a signature that fails to
match, and paying the buyer for one would be a bounty on lying. A mismatch pays nobody — the bond is burned,
so a seller who really swapped the item still loses it while a buyer gains nothing by claiming a swap. Only
positive facts are ever proven, on this side as on the payment side (`AUDIT.md` SC-AUDIT-04). The bond
is a flat, seller-chosen CTC stake — deliberately **not** a percentage of `price`, since that would
need a CTC/payToken price oracle and reintroduce exactly the oracle dependency PayGo avoids elsewhere.
A `SellerPassport` (ERC-5192, mirrors `CreditPassport`) waives the bond after 4 chip-matched deliveries
with zero proven mismatches. Full spec: `../docs/08-proof-of-custody.md`. Implemented and tested
(`test/CustodyRouter.t.sol`, `test_custody_*` in `test/PayGoEscrow.t.sol`), independently reviewed twice
(`AUDIT.md`: two multi-agent passes, every surviving finding fixed with a regression test) and deployed on
testnet (addresses in the README).

## Setup
```sh
npm i && forge test                       # unit tests (precompiles mocked via vm.etch) + real-proof decode fixture
cp .env.example .env                      # key + RPCs
sh script/deploy.sh                       # Sepolia: Router, TestUSDC · CC3: Escrow(+Passport), DemoAsset — note --libraries EvmV1Decoder
npm run worker                            # relayer + autopay + checkout UI at http://localhost:8787
sh script/demo.sh order|pay|default|finalize|claim|withdraw|show|passport|attest-origin|attest-delivery|bond|withdraw-bond|claim-bond
node script/gas-probe.mjs                 # freshness table
```
Versions pinned: `@gluwa/usc-sdk@0.18.0`, `@gluwa/usc-contracts@0.1.2`, solc 0.8.30, EvmV1Decoder testnet lib `0x731c345d79Fb8BbDC541f9DF3b6317585F849F9f`, chainKey Sepolia = 1 (CC3 testnet; mainnet differs — constant per env).

## Assumptions & limits (stated)
1. A buyer with no passport pays the full 40 % deposit. The 15 % tier is a convenience discount, never a
   security boundary; a two-wallet collusion can manufacture history (raised cost, not eliminated — see
   `AUDIT.md` MEDIUM-2). The asset stays escrowed and reverts to the seller on default regardless.
2. The seller carries the asset risk (standard hire-purchase); no lender pool in v1.
3. A late payment never cures (v1). "Cure with penalty" is a product knob, not a protocol change.
4. Return path to Ethereum is out of scope until writability ships.
5. Real USDC on Sepolia is rationed; `TestUSDC` exposes the same permit + EIP-3009 surface — swapping the address is zero code change.
6. The worker is a convenience: `settle`, `declareDefault`, `finalizeDefault` and autopay submission are all permissionless; the buyer can always save themselves with a proof.

## Security review
See `docs/AUDIT.md` (pre-deployment review, findings and fixes).
