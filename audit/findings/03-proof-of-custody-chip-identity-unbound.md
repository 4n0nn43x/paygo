# 03 — Proof-of-Custody's chip identity has no integrity anchor: unrestricted attestation submission defeats both the squat-protection and the bond/passport backstop

**Severity: High** (Variant A, cleanly fixable) **+ Medium-High design-level residual** (Variant B, not closed by the same fix). **Status: Variant A FIXED. Variant B remains an accepted, documented residual — not fixable by a code patch alone.**
Regression: `test/PoC_ChipSquat.t.sol` (`test_squatAttemptRejected_thenRealSellerBindsCleanly`,
`test_buyerCannotSquatOwnOrdersOriginSlot`), `test/PayGoEscrow.t.sol`
(`test_custody_originSquatByNonSellerRejected`). `test/PoC_SellerPassportForgery.t.sol` was updated to
confirm Variant B survives post-fix (using two attacker-controlled addresses instead of one, since the
submitter check now requires the Delivery submitter to equal `o.buyer`).

## Root cause (one paragraph, per the composition refuter's synthesis)
`CustodyRouter.attestPossession` (`contracts/CustodyRouter.sol:31-35`) lets anyone assert an arbitrary self-generated keypair as "the chip" with no binding to a real physical device — it verifies only that a signature recovers to the caller-supplied `chip` address. `PayGoEscrow._applyCustodyLog` (`contracts/PayGoEscrow.sol:259-288`) compounds this by decoding the event's `submitter` field (`address chip, uint8 role, ) = abi.decode(log.data, ...)` at line 264) and then **discarding it** — never checking it against `o.seller`/`o.buyer` on either the Origin (`role==0`) or Delivery (`role==1`) branch. `submitter` is confirmed to be the genuine, non-spoofable `msg.sender` of whoever called `attestPossession` on Sepolia (`CustodyRouter.sol:34`, `emit PossessionAttested(escrow, orderId, chip, role, msg.sender)`) — the data needed to close half of this is already sitting in the event, unused.

## Variant A — third-party origin-slot squatting (High, fully fixable)
An order is created normally by an honest seller with a real chip and a posted bond. Because `attestPossession` is fully permissionless and `_applyCustodyLog`'s role==0 branch has no identity check (`if (o.chipId != address(0)) return; o.chipId = chip;` — first attestation wins, permanently), **any unrelated third party** (or the buyer) can generate a throwaway keypair, self-sign the *public* digest for that order (`nextOrderId` is sequential, `OrderCreated` is a public event — nothing requires the digest's inputs to be secret), and get it proven-and-applied before the seller's real chip ever attests — nothing requires Origin to be submitted promptly at listing. `o.chipId` is now permanently bound to garbage. When the buyer later honestly scans the *real* chip at delivery, it doesn't match → `custodyDisputed=true` → the honest seller's bond is slashed to the buyer, and `SellerPassport` permanently flags them `disputed` (a lifetime ban from ever waiving a bond again) — despite no actual fraud.

**Proof**: `test/PoC_ChipSquat.t.sol` — `forge test --match-path test/PoC_ChipSquat.t.sol -vvv`:
```
[PASS] test_squatterStealsBondFromHonestSellerViaBogusOrigin() (gas: 308978)
```
Confirmed by refutation: `test_custody_secondOriginAttestationIgnored` (the existing regression test) only covers a benign race between two legitimate submissions, never an adversarial one — it does not defend against this.

**Fix, confirmed sufficient by a dedicated composite-impact refutation pass**: require `submitter == o.seller` for role==0 attestations and `submitter == o.buyer` for role==1 attestations, enforced in `_applyCustodyLog`. Since `submitter` is real, unspoofable `msg.sender`, this closes Variant A completely — the squatter's own address is neither `o.seller` nor `o.buyer`, so their bogus attestation is filtered like any other inapplicable log (consistent with the existing "filters, not reverts" pattern).

## Variant B — seller self-forges a clean SellerPassport, then defrauds a real buyer with zero bond backing (Medium-High, NOT closed by the Variant-A fix)
A single wallet (the seller) opens a throwaway, minimal-cost order (`n=1`, `price=1`, `buyer` = a throwaway address that never has to act), generates one keypair, and submits **both** Origin and Delivery attestations themselves — legitimately, as `o.seller` and coincidentally also as the inert `o.buyer` of their own fabricated order. `submitter == o.seller`/`== o.buyer` is trivially true both times, because the attacker genuinely is both parties on their own sham order. Repeating this four times flips `SellerPassport.waivesBond(seller)` to `true` (`confirmed >= 4 && disputed == 0`, no order-value weighting, no time gate). The seller then opens a **real** order against a real, uninvolved victim buyer with `msg.value == 0` — no bond posted at all. If the seller ships a swapped item and it's later caught, `withdrawBond` reverts `"no bond"` (`amount > 0` check fails on a zero bond): the victim's only on-chain compensation mechanism for a proven chip swap pays exactly zero.

**Proof**: `test/PoC_SellerPassportForgery.t.sol` — `forge test --match-path test/PoC_SellerPassportForgery.t.sol -vvv`:
```
[PASS] test_sellerForgesWaiverWithNoBuyerAndNoRealDelivery() (gas: 2269541)
Logs: gas for 4 self-forged 'confirmed' custody records: 2161514
```
Confirmed: the asset-side escrow (allowlist, pull-pattern `claimAsset`/`withdrawAsset`) is entirely orthogonal and unaffected — this attack disables only the custody-bond compensation mechanism, not the NFT escrow itself. Refutation refined one point: the attacker needs *real*, allowlisted collateral temporarily locked per throwaway order (not literally free, since a production allowlist wouldn't offer `DemoAsset`'s free public mint) — but every wei of bond is fully and immediately reclaimed, so there is no permanent capital cost, only temporary collateral commitment.

**Why the Variant-A fix (submitter checks) does not close this**: a dedicated refutation pass confirmed the deeper root cause is that `chip` identity is never bound to a real device at all — a legitimate seller, submitting genuinely as themselves, can still mint a throwaway keypair and call it "the chip." A submitter check validates *who* submitted, not *whether the chip is real*. Closing this fully needs an out-of-band chip-provisioning/attestation mechanism (issuer-signed chip registration, hardware attestation) that the current design does not have and, per `docs/08-proof-of-custody.md`'s own stated limitations, was not scoped for v1. **This is new, though**: that doc's limitations section acknowledges "same chip, wrong object" (Origin and Delivery match, but the item was fake from the start) and names the bond + `SellerPassport` as the residual deterrent for exactly that gap — Variant B shows that residual deterrent can itself be minted for free by the same unbound-chip defect, which the doc does not anticipate.

## Variant C — considered, refuted as not severity-bearing
A fourth candidate ("a fraudulent seller withholds their own Origin attestation so a buyer's honest, mismatch-proving Delivery scan gets silently no-op'd and its nullifier permanently burned before it can ever be credited") was hunted, independently reproduced with a fresh PoC (`test/PayGoEscrowCustodyOrderPoC.t.sol`), and then **refuted**: the "permanently burned, can never be proven again" premise is false. `CustodyRouter.attestPossession` has no application-level nonce — the buyer's original (public, already-broadcast) `(chip, role, signature)` tuple can be resubmitted verbatim by anyone in a **new** Ethereum transaction, producing a fresh `(height, txIndex)` and therefore a fresh, un-burned nullifier. The refutation PoC demonstrates the resubmission succeeding and the bond correctly landing on the buyer:
```
[PASS] test_refutation_resubmittingSameAttestationInNewTxWinsTheBond() (gas: 841676)
```
Net effect of this variant, once the false "permanent" premise is stripped: one extra cheap transaction and some delay for the victim, not data loss. Folded into the root-cause writeup as a one-line addendum, not reported as a standalone finding.

## Severity reasoning
Variant A is High: concrete victim (an honest seller), fully reachable by any third party at zero real cost, cleanly and completely fixable with a one-line-per-branch guard. Variant B is reported separately as a Medium-High **design-level residual** rather than folded into "High" outright, because it cannot be fixed the same cheap way and is qualitatively closer to the already-accepted `docs/AUDIT.md` MEDIUM-2 residual (buyer-side CreditPassport sybil) than to a straightforward code bug — except it is worse in kind: MEDIUM-2 requires two independently-acting wallets moving real value on a real schedule; Variant B requires one wallet, zero cooperating counterparty, and only temporarily-committed (not spent) collateral.

## Fix applied (Variant A) / accepted residual (Variant B)
- **Variant A — FIXED**: `_applyCustodyLog` (`contracts/PayGoEscrow.sol`) now decodes and enforces
  `submitter`: `require submitter == o.seller` on the role==0 branch, `submitter == o.buyer` on role==1.
  A squatter's bogus attestation is now filtered exactly like any other inapplicable log — cheap,
  complete, no design trade-off, matches what the composite-impact refuter confirmed would work.
- **Variant B — not fixed, accepted residual, now documented**: no code-only fix closes this within the
  current trust model (a legitimate seller controlling a second address as `buyer` passes both submitter
  checks trivially). `docs/AUDIT.md` and `docs/08-proof-of-custody.md` are updated to name this
  explicitly, alongside the structurally identical `MEDIUM-2` buyer-side residual. Real closure needs
  out-of-band chip provisioning (a registered, issuer-signed chip allowlist) — out of scope for v1, same
  treatment as `MEDIUM-2`.
