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

## LOW-1 — Hostile/buggy asset `transferFrom` bricks completion — **FIXED**
A seller-supplied ERC-721 whose `transferFrom` reverted on the release leg could brick `settle`/
`finalizeDefault` entirely — since the asset transfer was pushed inline, a bad call there rolled back
the whole transaction, including every *other* order's proof settled in the same batch (the nullifier
writes too, since a revert unwinds all of it). The buyer had already paid on Ethereum with no recourse.
**Fix**, two layers (`PayGoEscrow.sol`):
1. **Allowlist** — `createOrder` now requires `allowedAssets[address(asset)]`, fixed at deploy time in
   the constructor (no admin, no add/remove function — zero governance, consistent with the rest of the
   protocol). A malicious asset contract can no longer be listed at all.
2. **Pull, not push** — `settle`'s Completed branch and `finalizeDefault` no longer call `transferFrom`.
   They only flip status. Two new permissionless functions, `claimAsset` (buyer) and `withdrawAsset`
   (seller), do the actual release, each an isolated external call: if the asset's `transferFrom` reverts,
   only that one claim fails — it can no longer brick a shared settle batch or another order's release.
Regression: `test_createOrder_rejectsUnlistedAsset`, `test_claimAsset_hostileAssetDoesNotBrickSettleBatch`.
**Residual**: the buyer still doesn't receive the good if a *whitelisted* asset later misbehaves (e.g. a
bug shipped after review) — the allowlist raises the bar to "vetted code", it doesn't make an arbitrary
promise enforceable. That gap (does the token represent something real) is a real-world trust problem no
on-chain check closes; out of scope for v1.

## LOW-2 — acknowledged
- `payWithPermit` pulls from `msg.sender` (the permit signer must be the caller) — the 1-click buyer
  path; the relayer path is `payWithAuthorization`. Documented, not changed.

## Independent multi-agent audit pass (2026-08-31) — Proof-of-Custody surface, `withdrawBond`, `CreditPassport`

The "not yet independently reviewed" flag below was resolved by a full `sc-audit` pass: 4 hunters (asset
custody, cross-chain proof/signatures, batch DoS/reentrancy/access-control, passport gaming) run in
parallel, then 8 refuters (3 lenses each on the two most consequential candidates, 2 each on the others)
tasked specifically to kill every finding. Three survived refutation with executed PoCs; one candidate
was hunted, reproduced, and then correctly refuted. Full writeup: `audit/00-recon.md` +
`audit/findings/`. Summary:

- **`audit/findings/01-credit-passport-volume-overflow-dos.md` — High — FIXED.** `CreditPassport.record`'s
  `r.volume += uint128(amount)` had no ceiling on `amount` (only a floor) and `payToken` was never
  allowlisted (only `asset` was) — an attacker could pin a targeted `records[victim].volume` at
  `type(uint128).max` for near-zero cost, after which every future `settle()` naming that victim as
  buyer reverted permanently (Panic 0x11, no admin/reset path).
  **Fix**: `CreditPassport.Record.volume` is now `uint256` (removes the truncating cast entirely — it's
  informational, never gates `depositBps`); `createOrder` now requires `allowedPayTokens[payToken]`, a
  new constructor-fixed allowlist mirroring `allowedAssets`. Regression: `test/PoC_VolumeOverflow.t.sol`.
- **`audit/findings/02-withdraw-bond-no-recovery-path.md` — Medium — FIXED.** `withdrawBond`'s native-CTC
  payout (`to.call{value: amount}("")`) had no retry-with-different-address/sweep path if the resolved
  recipient could never accept a bare transfer (no payable `receive`/`fallback`) — funds weren't burned
  (they sat correctly earmarked in the contract's own balance) but per-order bookkeeping could get
  permanently wedged.
  **Fix**: `withdrawBond` now only resolves (no external call, credits a pooled `claimableBond[to]`); a
  new `claimBond()`, pulled by the recipient itself, does the actual payout — matches the pull-pattern
  discipline `claimAsset`/`withdrawAsset` already use. Regression: `test/ZZBondLockPoC.t.sol`,
  `test/PayGoEscrow.t.sol::test_claimBond_nonPayableRecipientDoesNotBrickResolution`.
- **`audit/findings/03-proof-of-custody-chip-identity-unbound.md` — High (Variant A, FIXED) +
  Medium-High design residual (Variant B, ACCEPTED, documented).** `_applyCustodyLog` decoded
  `submitter` (the real, unspoofable `msg.sender` of the attestation) and never checked it against
  `o.seller`/`o.buyer`. **Variant A** (origin-slot squatting by an unrelated third party, wrongly
  slashing an honest seller's bond later) — **fixed**: `_applyCustodyLog` now requires
  `submitter == o.seller` for role==0 and `submitter == o.buyer` for role==1. Regression:
  `test/PoC_ChipSquat.t.sol`. **Variant B** (a seller legitimately self-forges both Origin and Delivery
  — using a second address they also control as `buyer` — to build a fake clean `SellerPassport`,
  waiving the bond requirement, then defrauds a real buyer with zero bond backing) is **not** closed by
  that same fix — a legitimate submitter can still self-authenticate a fake chip from two addresses they
  both control; needs out-of-band chip provisioning to close for real. Accepted as a residual, same
  treatment as `MEDIUM-2` below. See the updated limitations section in `docs/08-proof-of-custody.md`.
  Regression (confirms the residual still stands post-fix): `test/PoC_SellerPassportForgery.t.sol`.
- A fourth candidate (fraudulent seller withholds their own Origin attestation so a buyer's honest,
  mismatch-proving Delivery scan gets silently no-op'd and its nullifier burned) was hunted, independently
  reproduced, and then **refuted**: `CustodyRouter.attestPossession` has no application-level nonce, so
  the same public `(chip, role, signature)` can be resubmitted in a fresh Ethereum tx, producing a fresh
  nullifier — the griefing costs the victim one extra transaction and some delay, not permanent data
  loss. See `test/PayGoEscrowCustodyOrderPoC.t.sol` for both the reproduction and the refutation.

The two acknowledged, unresolved points from the original self-review — a leaked chip signature is an
inherent signature-scheme risk (same class as a leaked EIP-3009 authorization, not separately
mitigated), and precompile/`EvmV1Decoder` internals are out of scope (vendored) — stand as-is.
Nullifier domain separation between `settle` and `settleCustody` was independently re-verified by the
cross-chain hunter and holds (no collision, fixed-width packed fields on both sides).

**All three findings above are now fixed in the contracts** (Variant B of Finding 03 is an accepted,
documented residual, not a code bug — see its entry). Suite: `forge test` → 47 passing, up from 25.
Deployed testnet addresses are stale as of these changes; see the README note for the required v3
redeploy before the next live demo.

## Checked and OK (from the review)
Nullifier scope (fixed-size `keccak(chainKey‖height‖txIndex)`, no cross-order replay); the 5 checks
present and tested; batch nullifiers roll back on revert; state machine has no reachable-but-exitless
state; `declareDefault` targets the earliest unpaid installment on the attested clock with grace >
attestation latency; `uint8`/installment bounds; `createOrder` split conserves `price`; EIP-3009 replay
and domain binding on the token; passport soulbound; the two clocks are not conflated.

---

# Web checkout review (web-audit skill)

Run on `web/index.html` + the worker's HTTP handler. The signing flow was verified **correct** end to
end (autopay nonce matches `PayGoRouter.authNonce` byte-for-byte; EIP-712 domain and Permit /
ReceiveWithAuthorization types match `TestUSDC`; CC3 chainId hex `0x18e8f` correct; the HIGH-1 payee
binding holds; the relayer never burns gas on junk — a bad authorization reverts at `estimateGas` and is
never sent; no secret exposure). Findings, all fixed:

## WEB-1 — Stored XSS via `/authorizations` → `/state` → worker log — **FIXED**
`POST /authorizations` stored the body verbatim, `GET /state` echoed it, and `refreshWorker` rendered it
with `innerHTML`; `orderId`/`installmentNo` are attacker-controlled, and the endpoint is CSRF-reachable
(text/plain simple request). Payload executed in the wallet-connected origin.
**Fix**: the worker log is now built with `textContent` (`replaceChildren`), never `innerHTML`; and the
POST handler validates every field (addresses, hex, integer ranges, numeric strings) and rejects
anything malformed. A served CSP (`default-src 'none'`, pinned script/connect/img) is the backstop.

## WEB-2 — Unbounded `/authorizations` DoS — **FIXED**
No cap, no dedup, whole-file rewrite per POST. **Fix**: 64 KB body limit, ≤64 per request, queue capped
at 1000, dedup on `(orderId, installmentNo, from)`.

## WEB-3 — No SRI / no CSP — **FIXED**
`integrity="sha384-…"` + `crossorigin` on the ethers CDN tag; CSP header on the served page pinning
script to cdnjs, connect to the two RPCs, img to the QR host.

## WEB-4 / demo — passport `volume` display inflated by CLI parse — **FIXED (harness)**
The escrow correctly accepts `amount >= due`; the CreditPassport `volume` counter therefore records
whatever was actually paid. A bug in `script/demo.sh pay` mis-parsed `cast`'s abbreviated output
(`40000000 [4e7]` → `400000004e7`), so the CLI over-paid and inflated one testnet buyer's `volume`.
Purely cosmetic — `depositBps` uses `honored`/`defaulted`, never `volume` — and fixed by parsing the
amounts array robustly. The UI-driven flow always used the exact on-chain `amounts[i]` and was never
affected.
