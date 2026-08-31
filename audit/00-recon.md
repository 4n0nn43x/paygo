# 00 — Recon: PayGo (Creditcoin/Attestcoin BUIDL, internal pre-submission audit)

## Platform
No bounty platform — this is a hackathon submission (BUIDL CTC 2026 Fall), not a Sherlock/C4/Cantina/
CodeHawks/Immunefi contest. No README Q&A, no fixed severity rubric. Applying general Solidity security
judgment (Critical/High/Medium/Low) with the same rigor the skill demands elsewhere: named attacker,
concrete call sequence, quantified loss, executed PoC — not platform-specific thresholds.

Working tree is **uncommitted** (`git status --short` shows 12 modified + 3 new files on top of
`d32421a`, 2026-08-20). Permalinks below point at file:line in the working tree, not a GitHub commit —
flagged explicitly per finding rather than fabricating a commit reference.

## Scope
Hand-scoped (the skill's `scope.sh` mis-globbed `node_modules` — path-matching bug, EXCLUDE pattern
requires a leading `/` that `sed 's|^\./||'` strips first). Actual in-scope contracts:

| File | Lines | Chain | New this session? |
|---|---|---|---|
| `contracts/PayGoEscrow.sol` | 358 | Creditcoin | extended (pull pattern, allowlist, custody) |
| `contracts/PayGoRouter.sol` | 72 | Sepolia | unchanged |
| `contracts/CustodyRouter.sol` | 36 | Sepolia | **new** |
| `contracts/CreditPassport.sol` | 62 | Creditcoin | unchanged |
| `contracts/SellerPassport.sol` | 64 | Creditcoin | **new** |
| `contracts/Attestcoin.sol` | 29 | interfaces | unchanged |
| `contracts/Demo.sol` | 41 | test/demo token+asset | unchanged |

Deploy commit for the **live testnet contracts** is the prior HEAD (v2, pre-this-session) — the code
below is not yet deployed anywhere. `EvmV1Decoder` (linked library, `@gluwa/usc-contracts@0.1.2`) and
the two precompiles (`0x…0FD2` BlockProver, `0x…0fD3` ChainInfo) are out of scope: vendored/native,
not ours to fix.

## Declared invariants (from docs/AUDIT.md, docs/02-mecanisme.md, docs/08-proof-of-custody.md — verbatim intent)
1. Nullifier checked and set **before** any business logic on every proof path (`settle`, `settleCustody`).
2. `receiptStatus == 1` required — the precompile does not check it.
3. `log.address_ == ROUTER` / `== CUSTODY_ROUTER` — signature-alone filtering is forgeable by any contract.
4. A single non-applicable log in a batch must not revert the whole batch (MEDIUM-1 regression, tested).
5. Asset/bond release is pull, never push — a hostile `transferFrom` or reverting bond recipient must
   only fail its own claim, never brick a shared `settle`/`settleCustody`/`finalizeDefault` call (this
   session's own stated invariant, LOW-1 in AUDIT.md).
6. `createOrder`'s asset must be on `allowedAssets` — fixed at deploy, no admin add/remove.
7. Custody bond is never a percentage of `price` — no CTC/payToken oracle exists, by design.
8. `chipId` binds once (first Origin attestation wins), never reassignable.
9. Late payment never cures (`height > deadline(id, no)` → skipped, not applied).
10. `declareDefault` targets the **earliest unpaid** installment on the attested clock.
11. Passport records are facts only, self-consuming (`depositBps`, `waivesBond`), never externally settable.

## Actors and trust
| Actor | May call | Trusted NOT to |
|---|---|---|
| Seller | `createOrder` (names buyer, asset, schedule, price, bond), `withdrawAsset`, `withdrawBond` | dictate buyer's deposit tier beyond passport rule; self-deal (blocked: `buyer != msg.sender`) |
| Buyer | pays on Sepolia via Router, `claimAsset`, `withdrawBond` | nothing structurally required of them — silence just risks default |
| Anyone (worker/relayer/stranger) | `settle`, `settleCustody`, `declareDefault`, `finalizeDefault`, `attestPossession`, `claimAsset`, `withdrawAsset`, `withdrawBond` — **every state-changing escrow function is permissionless** | — no admin role exists to misuse |
| Chip (EIP-5791 keypair) | nothing on-chain directly — its signature is submitted by anyone | its own key custody is off-protocol; a leaked chip key is an acknowledged residual (AUDIT.md) |
| Router / CustodyRouter | emits the one event escrow trusts | forging `InstallmentPaid`/`PossessionAttested` semantics (both stateless, no admin) |

No owner, no pauser, no upgradeability anywhere in scope. `allowedAssets` is the only allowlist and it
is constructor-fixed.

## Value flow (exit points = drain candidates)
- **ERC-20 payToken** (Sepolia): buyer → `payee` directly via Router (`transferFrom`/`permit`/EIP-3009).
  Router never custodies payToken itself (no balance to drain — `transferFrom` target is `payee`, not
  the Router).
- **Escrowed ERC-721 asset** (Creditcoin): seller → `PayGoEscrow` at `createOrder`, held until
  `claimAsset` (→ buyer) or `withdrawAsset` (→ seller). **Exit candidate 1.**
- **Native CTC custody bond** (Creditcoin): seller → `PayGoEscrow` (`msg.value` at `createOrder`), held
  until `withdrawBond` resolves it to seller or buyer. **Exit candidate 2.**
- No pooled funds, no shared vault — every order's assets/bond are logically isolated by `orderId`, so
  a drain candidate must show state confusion *between* orders, not just theft *within* one.

## State-changing external entry points (permissionless unless noted)
`PayGoEscrow`: `createOrder` (payable), `settle`, `settleCustody`, `declareDefault`, `finalizeDefault`,
`claimAsset`, `withdrawAsset`, `withdrawBond`.
`PayGoRouter`: `payInstallment`, `payWithPermit`, `payWithAuthorization`.
`CustodyRouter`: `attestPossession`.
`CreditPassport` / `SellerPassport`: `record` (escrow-only, `require(msg.sender == escrow)`).

## Static analysis (Slither + Aderyn, full run — see static.sh output)
- Slither: all "reentrancy" hits are event-emitted-after-external-call in functions with no reentrant
  state to protect (see hunt below for the one that actually matters: `withdrawBond`'s raw `.call`).
  One `timestamp`-comparison hit in `Demo.sol` (test double, out of scope).
- Aderyn: H-1 reentrancy (same shapes as Slither), H-2 unsafe casting (mirrors the `uint160`/`uint128`
  truncations already flagged `LOW` in prior audit rounds for `CreditPassport`; new instances in
  `SellerPassport` inherit the same triage). Rest is L-tier style noise (pragma, literals, loop-`require`).
- **Coverage gap, read as a hunting map**: `SellerPassport.sol` 32%/50% (lines/branches),
  `CreditPassport.sol` 48%/62%, `PayGoEscrow.sol` 76% branches. The untested branches in
  `PayGoEscrow.sol` are the hunt's first stop.

## Coverage gate (OWASP SCS top 10, walked after the hunt — see `references/method` in the sc-audit skill)

| ID | Category | Looked? | Conclusion |
|---|---|---|---|
| SC01 | Access control | Yes — every state-changing entry point traced (see table above); actor-axis hunter dedicated to it | **Finding 03**: `submitter` decoded but never checked against `o.seller`/`o.buyer` in `_applyCustodyLog` |
| SC02 | Business logic | Yes — all 4 hunters, cross-referenced against declared invariants | **Findings 01, 03**: business-logic gaps in payToken validation and custody role handling |
| SC03 | Price oracle manipulation | Yes — structurally absent by design (the whole pitch is "no price oracle"); confirmed via grep, no oracle call exists anywhere in scope | N/A, not a gap in the pass |
| SC04 | Flash-loan-facilitated | Yes — asked of every candidate whether a flash loan removes a capital constraint | None found: Findings 01 and 03 already require near-zero capital; Finding 03B's bond is reclaimed instantly regardless of amount, so a flash loan adds nothing |
| SC05 | Input validation | Yes | **Finding 01**: `payToken`/`amount` unvalidated; **Finding 03**: `chip`/`submitter` unvalidated |
| SC06 | Unchecked external calls | Yes | **Finding 02**: `withdrawBond`'s `.call` has no recovery path on failure |
| SC07 | Arithmetic errors | Yes — deposit dust-remainder math specifically re-derived by the actor-axis hunter (found benign, `sum(amounts)==price` holds) | **Finding 01** is this category |
| SC08 | Reentrancy | Yes — Slither/Aderyn cross-referenced against every external call by hand | No exploitable reentrancy found; every real state-mutation follows CEI where it matters (the one near-miss, `withdrawBond`, is a stuck-funds bug, not a reentrancy bug — see Finding 02) |
| SC09 | Integer overflow/underflow | Yes | **Finding 01** is this category directly (explicit narrowing cast + checked-arithmetic overflow) |
| SC10 | Proxy/upgradeability | Yes — structurally absent; no proxy, no `delegatecall`, no upgradeable pattern anywhere in the 5 in-scope contracts (confirmed by reading all of them) | N/A, not a gap in the pass |

## Deliverables
- `audit/00-recon.md` — this file
- `audit/findings/01-credit-passport-volume-overflow-dos.md` — High
- `audit/findings/02-withdraw-bond-no-recovery-path.md` — Medium
- `audit/findings/03-proof-of-custody-chip-identity-unbound.md` — High (Variant A) + Medium-High design residual (Variant B)
- PoCs, all passing against the real contracts (`forge test`, 43/43 green): `test/PoC_VolumeOverflow.t.sol`, `test/ZZBondLockPoC.t.sol`, `test/PoC_ChipSquat.t.sol`, `test/PoC_SellerPassportForgery.t.sol`, `test/PayGoEscrowCustodyOrderPoC.t.sol` (includes one refutation test disproving a fourth candidate)

## What was NOT covered (say so plainly, per the skill's own rule against silent truncation)
- `EvmV1Decoder`/precompile internals — vendored, out of scope, not ours to fix; analysis assumes merkle-inclusion verification is sound.
- No fuzzing was run anywhere — every finding is a deterministic PoC, not a fuzz-discovered one. A fuzz campaign on `amount`/`price`/`n` combinations in `createOrder` was not attempted and could surface more of the same class as Finding 01.
- `CreditPassport.sol`'s and `SellerPassport.sol`'s ERC-5192/ERC-721-read-surface functions (`tokenURI`, `supportsInterface`, etc.) were not adversarially reviewed — low value target, but not zero-checked either, just deprioritized.
- No live-network / testnet-deployed verification — every PoC is a Foundry unit test against the working-tree source with the precompiles mocked, matching the project's own existing test methodology.

## Hunt plan
Slicing by module (payment core is well-trodden from the prior audit round; the two new surfaces —
Proof-of-Custody and the pull-pattern release functions — are one session old and self-reviewed only,
exactly what `docs/AUDIT.md` already flags as owed). Four hunter slices, run in parallel:
1. `PayGoEscrow.sol` payment/default/batch core (re-check under adversarial lens, not just regression)
2. `PayGoEscrow.sol` + `CustodyRouter.sol` Proof-of-Custody surface (new, unaudited)
3. `PayGoEscrow.sol` pull-pattern release (`claimAsset`/`withdrawAsset`/`withdrawBond`) + bond accounting
4. `CreditPassport.sol` / `SellerPassport.sol` fact-ledger + `createOrder`'s deposit/bond sizing math
