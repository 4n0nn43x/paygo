# 01 — `CreditPassport.volume` uint128 overflow permanently bricks `settle()` for a targeted buyer

**Severity: High** (boundary with Critical — argued below). **Status: FIXED.** Regression:
`test/PoC_VolumeOverflow.t.sol` (`test_unlistedPayTokenRejectedAtCreateOrder`,
`test_largeAmountNoLongerOverflowsVolume_andRealPaymentStillSettles`).

## Where
- `contracts/CreditPassport.sol:24` — `if (ok) { r.honored++; r.volume += uint128(amount); } else r.defaulted++;`
- `contracts/PayGoEscrow.sol:212` — `passport.record(o.buyer, true, amount);` (unconditional, no try/catch)
- Enablers: `contracts/PayGoEscrow.sol:121` (`price >= n` — no ceiling), `:124` (only `asset` is allowlisted, `payToken` never is), `:207` (`amount < o.amounts[no]` — a floor check only, no ceiling)

## The bug
`_applyLog`'s five business checks (status, installment index, payee/token/amount match, deadline) are deliberately **filters** — a failing log is skipped (`return`), never reverted, specifically so one bad log can't brick a shared `settle()` batch (see the comment at `PayGoEscrow.sol:184-188`, and the MEDIUM-1 fix this already codifies in `docs/AUDIT.md`). `passport.record(...)` at line 212 sits *after* all five filters, with no such protection: it's an unconditional external call, and `CreditPassport.record`'s `r.volume += uint128(amount)` is checked arithmetic on a field that can be driven to its ceiling by a single attacker-chosen `amount`.

Nothing bounds `amount` from above anywhere in the payment path (`PayGoRouter.sol` has no `require` on it at all), and `payToken` is never allowlisted — only `asset` is (`createOrder`, line 124). So an attacker can:

1. Deploy a free, self-mintable ERC-20, open a throwaway 1-installment order naming `buyer = victim` (any address — `createOrder`'s only constraint on `buyer` is `buyer != msg.sender`, no consent from the named buyer is required), pay it with `amount = type(uint128).max` of the worthless token, and `settle()` it — `records[victim].volume` lands exactly on `type(uint128).max`, no overflow yet.
2. Open a second throwaway order, same `buyer = victim`, any nonzero payment. `settle()` now reverts with Panic `0x11` inside `passport.record`, unwinding the whole transaction.
3. From this point, **every future `settle()` call for any order — created by anyone, paid for real, in real payToken — that names `victim` as buyer and reaches an honored installment reverts permanently.** There is no admin, no reset, no decrement path anywhere in `CreditPassport.sol` or `PayGoEscrow.sol`.

## Proof
`test/PoC_VolumeOverflow.t.sol` — `forge test --match-path test/PoC_VolumeOverflow.t.sol -vvv`:
```
[PASS] test_attackerPermanentlyBricksVictimSettleViaVolumeOverflow() (gas: 1216945)
```
The PoC constructs a **third, unrelated order** — a distinct `realSeller`, real USDC, a real posted custody bond, a legitimate on-schedule payment — and shows it still reverts (Panic 0x11) once `records[victim].volume` is pinned. This is not self-inflicted damage to the attacker's own throwaway orders; it hits an innocent third party's genuine order.

Confirmed independently by three refuters (reachability, guards, impact lenses), each reading the source directly and re-running the PoC. All agree the core claim holds.

## What does NOT hold — pre-empting overclaim
The original hunter additionally claimed the attacker (as seller on one of their own poisoned orders) could then `declareDefault`/`finalizeDefault` to seize the escrowed asset, on the theory that the victim's genuine on-time payment can never be recorded. **This compound claim is unproven**: the PoC never calls `declareDefault`/`finalizeDefault`/`withdrawAsset`, never advances the mocked attested clock past `deadline + GRACE`, and even if it did, the "real" order in the PoC belongs to `realSeller` (an honest third party), not the attacker — a completed default there benefits `realSeller`, not the attacker. Report only the proven DoS; do not present the asset-seizure extension as demonstrated.

## Severity reasoning
Argue High, not Critical, on the following grounds, stated so the boundary is explicit: no funds are drained from the protocol as a whole, and a victim can sidestep the block for **future** orders by using a fresh address (their historical passport is lost, but new business isn't blocked). It survives as High rather than dropping to Medium because: it's permanent (no recovery), costs the attacker only gas plus a self-minted worthless token, requires no privileged position, and — critically — bricks settlement for **any in-flight order already naming the victim as buyer at the time of the attack**, which is real, uncapped loss for whoever's payment gets stuck mid-flight. A defender could argue Critical given "permanently and cheaply denies a core protocol function to an arbitrary named victim, no privilege required" — that argument is not unreasonable; this report takes the more conservative side but flags the disagreement.

## Fix applied
1. `CreditPassport.Record.volume` changed from `uint128` to `uint256` (`contracts/CreditPassport.sol`) —
   removes the truncating cast entirely; `volume` is purely informational (never gates `depositBps`),
   so there was no reason it needed to fit in 128 bits.
2. `createOrder` now requires `allowedPayTokens[payToken]` (`contracts/PayGoEscrow.sol`), a new
   constructor-fixed allowlist mirroring `allowedAssets` — closes the enabler that let an attacker name
   an arbitrary self-minted token in the first place.
Both changes required a new constructor parameter (`address[] allowedPayTokens_`); `script/deploy.sh`,
`test/PayGoEscrow.t.sol`, and every PoC file were updated accordingly.
