# PayGo — pre-deployment security review

An independent audit pass (the `sc-audit` skill) was run on the contracts before testnet deployment.
Findings and their resolution below; each fix ships with a regression test in `forge test`.

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
documented residual, not a code bug — see its entry) and live in the v4 deployment (README).

## Bond stranded on Defaulted orders (2026-09-03) — **FIXED**
`withdrawBond`'s timeout branch only fired for `Completed` orders. `bondRecipient` is otherwise set only by
a chip match/mismatch, so a buyer who never paid and never scanned (→ `finalizeDefault` → `Defaulted`) left
the seller's custody bond with no exit path at all.
**Fix** (`PayGoEscrow.sol`): `finalizeDefault` stamps `closedAt` (renamed from `completedAt`), and the
timeout branch accepts `Completed || Defaulted` — silence still favors the seller, same polarity as before.
Regression: `test_withdrawBond_timeoutAfterDefaultFavorsSeller`. Needs a redeploy (README).

## Second independent multi-agent audit pass (2026-09-03, pre-v5-deploy)

Four hunters (escrow lifecycle/bond, proof pipeline/nullifier, source-chain + relayer, actor axis) run in
parallel on the post-refactor source, then three refuters on different lenses. Slither + Aderyn + `forge
coverage` first (no protocol-level finding of their own: the reentrancy hits are calls into this contract's
own immutable children or the read-only precompile, and the `.call` in `claimBond` is the pull pattern).
Six findings survived refutation; two more were refuted at the claimed severity and are recorded as such.

## SC-AUDIT-05 — Asset release replays once the token is re-escrowed — **Critical — FIXED**
`claimAsset`/`withdrawAsset` checked only the order's terminal status, and a terminal status is absorbing.
After order 1 released a token, the same `(asset, tokenId)` re-escrowed in a later order could be pulled
straight back out by replaying order 1's release: the escrow is the owner again, so the ERC-721 transfer is
authorized. The new order's buyer paid in full and their `claimAsset` reverted for ever. Repossess-then-relist
is the core hire-purchase flow, not an edge case, and the call is unauthenticated.
**Fix**: a `released[id]` flag, set before the transfer on both legs.
Regression: `test_withdrawAsset_cannotBeReplayedAfterTheAssetIsRelisted`,
`test_claimAsset_cannotBeReplayedAfterTheAssetIsRelisted`.

## SC-AUDIT-06 — Unbounded schedule turns a filter into a panic — **High — FIXED**
`createOrder` bounded `firstDeadline`/`interval` only by epoch alignment, and `deadline()` is checked `uint64`
arithmetic *reached from inside `_applyLog`'s filter chain*. A seller could create a throwaway order whose
`deadline(id, 1)` overflows; the resulting log panics instead of being skipped, so any transaction carrying it
reverts for ever — re-opening exactly the poison-log DoS MEDIUM-1 was fixed to close, this time unfixably per
transaction (the nullifier is per source tx). Co-locating a victim's publicly submittable EIP-3009 autopay in
that same Sepolia transaction makes the victim's payment unsettleable and drives a wrongful default. The same
overflow also panics `declareDefault`, leaving the order with no exit.
**Fix**: `createOrder` requires `firstDeadline + n*interval + GRACE <= type(uint64).max`.
Regression: `test_createOrder_rejectsScheduleOverflowingUint64`.

## SC-AUDIT-07 — `declareDefault` on an order that does not exist yet — **High — FIXED**
An unwritten order reads `status == Active` (enum zero) with `deadline() == 0`, so any id above `nextOrderId`
could be driven to `DefaultAsserted` and then `Defaulted` — and `createOrder` never resets the lifecycle
fields, so the order was *born closed*. A third party could poison a run of future ids for gas and make every
order the protocol then creates stillborn; there is no admin and no reset. `_applyCustodyLog` already had the
missing existence check one function away.
**Fix**: `require(o.seller != address(0), "unknown order")` in `declareDefault`.
Regression: `test_declareDefault_rejectsUnknownOrder`.

## SC-AUDIT-04 — A chip mismatch was a bounty on lying — **High — FIXED (design change)**
`_applyCustodyLog` paid the custody bond to the buyer on a mismatch, on the stated ground that a mismatch is
"a cryptographic proof of substitution". It is not. A chip is a secp256k1 keypair and `attestPossession`
only checks that the signature recovers to the address presented as the chip, so a buyer who received the
genuine item can generate a key, attest Delivery with it, take the whole bond and brand the seller `disputed`
for ever — for one Sepolia transaction. Finding 03's own fix reasoning ("the submitter must be `o.seller` /
`o.buyer`") assumed the buyer is honest on role 1; that assumption is the bug. It also contradicted the
protocol's own axiom, stated in `CustodyRouter.sol`: only positive facts are ever proven.
**Fix**: only a MATCH is a positive proof and still releases the bond to the seller. A mismatch now resolves
to a burn address, so nobody is paid: the seller who really swapped the item still loses the bond, and the
buyer gains nothing by lying.
**Residual (assumed)**: a buyer can still destroy the bond and record a dispute against the seller for the
price of one transaction. That is griefing without profit, against a counterparty the seller chose — the same
class as MEDIUM-2, and not closable without out-of-band chip provisioning.
Regression: `test_custody_mismatchedChipBurnsBondAndPaysNobody`.

## SC-AUDIT-08 — Passport `volume` could be pinned at max — **Low — FIXED**
`record`'s `r.volume += amount` is checked arithmetic on unbounded attacker input. SC-AUDIT-01 widened the
type to `uint256` on the reasoning that a narrower one was the problem; `uint256` is also fixed width. The
real mitigation was `allowedPayTokens`, which carries an unstated precondition: every allowlisted token must
have a bounded supply. The token this repo deploys, `TestUSDC`, has a permissionless unbounded `mint`, so on
the testnet configuration a victim's volume could be pinned at max, panicking every later settle naming them.
Impact on a real-USDC deployment is nil; on the shipped demo configuration it is a wrongful-default vector.
**Fix**: the accumulator saturates instead of reverting. `volume` is informational and never gates
`depositBps`, so saturation loses nothing that matters.
Regression: `test_passport_volumeSaturatesInsteadOfBrickingTheBuyer`.

## SC-AUDIT-09 — Pre-signed installments outlive the order — **Medium — FIXED (mitigated)**
An EIP-3009 authorization commits to escrow, order, installment and payee, but not to the order still being
open. After a default and repossession the seller could still submit the remaining authorizations and collect
installments on a closed order — the escrow filters the logs, but the Ethereum-side transfer already happened.
The same holds for an installment the buyer already paid by hand. `TestUSDC` had no `cancelAuthorization`,
so the buyer had no remedy at all, and the claim that swapping in real USDC is "zero code change" was false
for the revocation half of EIP-3009.
**Fix**, two layers: `TestUSDC.cancelAuthorization` (the standard EIP-3009 function real USDC exposes), and
the relayer refuses to submit an authorization whose order is closed or whose installment already settled.
**Residual**: a malicious seller can still submit directly; revocation is the buyer's actual remedy, and it is
a race the buyer wins only by acting before `validAfter`.
Regression: `test_cancelAuthorization_revokesAPresignedInstallment`,
`test_cancelAuthorization_onlyTheSignerCanRevoke`.

## SC-AUDIT-10 — Unauthenticated autopay queue — **Medium-High — FIXED**
`POST /authorizations` validated field shapes but never verified the signature, and a duplicate
`(orderId, installmentNo, from)` was silently skipped. Anyone, from any origin, could take a buyer's queue
slot with a garbage entry; the buyer's real authorization was then dropped, the UI still said "close your
laptop", autopay never fired, and a late payment never cures. Sixteen requests also filled the 1000-entry cap
for everyone, permanently, since nothing was ever evicted. The dedup that made poisoning stick was introduced
by WEB-2's own fix.
**Fix**: the worker recovers the EIP-712 signature against the token's own ERC-5267 domain and rejects
anything that does not recover to `from`; a fresh valid signature replaces an unsent entry; dead entries
(errored, sent, expired) are pruned; a per-signer cap bounds one spammer; `GET /state` no longer publishes
`v`/`r`/`s`; and the checkout no longer claims autopay is armed when the relayer accepted nothing.

## Refuted at the claimed severity
- **Receipt-bloat DoS** — an attacker co-locating a victim's payment in a Sepolia transaction padded with
  junk logs raises the Creditcoin settle cost superlinearly. Measured against CC3's real 75M block gas limit,
  the threshold is ~3200 junk logs, not the ~1000 originally claimed, and the vector is strictly dominated by
  SC-AUDIT-06 (same primitive, no padding needed). Recorded as Low. The worker's fixed 2M gas limit, a real
  latent liveness bug, is fixed alongside: it now estimates and adds a margin.
- **Passport poisoning** — anyone can create an order naming any address as buyer, with a past deadline, and
  drive it to `Defaulted`, writing a permanent `defaulted` fact against an address that never consented. The
  mechanism is confirmed, but the impact is the 40 % deposit tier that every newcomer already has, and
  MEDIUM-2 already states the passport is a convenience discount and never a security boundary. Recorded as
  Low and accepted; note that `docs/02-mecanisme.md` promises a `Created ──deposit──> Active` transition the
  code has never had, which is a documentation defect corrected in that file.

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
