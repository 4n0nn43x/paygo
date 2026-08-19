# PayGo — pre-deployment security review

An independent audit pass (the `sc-audit` skill) was run on the contracts before testnet deployment.
Suite: `forge test` → 25 passing. Findings and their resolution below; each fix ships with a regression test.

## HIGH-1 — Autopay theft via unbound payee — **FIXED**
`payWithAuthorization` pulled the buyer's funds into the Router (signed) and forwarded `amount` to a
**caller-supplied** `payee` (unsigned). A submitter could set `payee = self` and steal every pre-signed
installment.
**Fix** (`PayGoRouter.sol`): the EIP-3009 nonce is no longer free — the buyer signs
`nonce = keccak256(escrow, orderId, installmentNo, payee)`, and the Router recomputes it from its
arguments. Change the payee and the nonce changes, so the signature no longer recovers the buyer and
the token reverts `invalid signature`. Consent now commits to where the money goes.
Regression: `test_payWithAuthorization_payeeIsBound`.

## MEDIUM-1 — Poisoned batch bricks co-located installments — **FIXED**
The nullifier is one key per source tx; `_apply` reverted the whole `settle` if any single log failed a
business check. A griefer could co-locate a failing log (e.g. an already-paid installment) with a
victim's payment in one tx and make it unsettleable forever — and, via the cure path, force a wrongful
default.
**Fix** (`PayGoEscrow.sol`): the 5 checks are now **filters**, not asserts — a non-applicable log is
skipped, applicable logs still settle. Proof integrity (nullifier + `verifyAndEmit`) stays a hard
revert in `settle`, before any log is touched.
Regression: `test_batch_poisonLogDoesNotBrickSibling`.

## MEDIUM-2 — Passport sybil to unlock the 15 % tier — **PARTIALLY FIXED, residual documented**
`depositBps` drops to 15 % after 4 honored installments; `createOrder` let a seller name themselves as
buyer and self-deal 4 tiny installments for gas only.
**Fix**: `createOrder` now rejects `buyer == msg.sender` (and `buyer == 0`), killing the single-wallet
self-deal.
**Residual (assumed)**: a two-wallet collusion can still manufacture history by completing real orders
between two addresses. This is inherent to permissionless reputation without identity — the cost is
raised (real orders, real gas over a real schedule) but not eliminated. We do not build identity infra
in v1; the passport is a convenience discount, never a security boundary — the asset stays escrowed and
reverts to the seller on default regardless of the buyer's passport.

## LOW — acknowledged
- `payWithPermit` pulls from `msg.sender` (the permit signer must be the caller) — the 1-click buyer
  path; the relayer path is `payWithAuthorization`. Documented, not changed.
- Seller-supplied ERC-721 with a reverting `transferFrom` can brick completion (buyer never receives the
  good, seller collected installments on Ethereum). Scam vector, no protocol drain; the buyer must trust
  the listed asset. `price >= n` and `each > 0` guards added to reject degenerate schedules.

## Checked and OK (from the review)
Nullifier scope (fixed-size `keccak(chainKey‖height‖txIndex)`, no cross-order replay); the 5 checks
present and tested; batch nullifiers roll back on revert; state machine has no reachable-but-exitless
state; `declareDefault` targets the earliest unpaid installment on the attested clock with grace >
attestation latency; `uint8`/installment bounds; `createOrder` split conserves `price`; EIP-3009 replay
and domain binding on the token; passport soulbound; the two clocks are not conflated.
