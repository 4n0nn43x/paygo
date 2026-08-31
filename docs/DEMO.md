# PayGo — demo script (3 acts, ~6 min on stage)

Latency rule: Attestcoin proofs land ~8-10 min after the Sepolia tx. So **pay everything but the last
installment before the slot**, and pay the last one ~12 min before you go on. The tracker then flips
live. Keep the recorded video as backup (P5 in the risk register).

## Setup (before the slot)
```sh
npm run worker                 # relayer + autopay + checkout UI on http://localhost:8787
sh script/demo.sh order        # order A (happy path) — or do it from the UI, section 1
sh script/demo.sh pay A 0..n-2 # or: UI → deposit (permit) + "sign once → autopay" with a 90 s gap
# order B: same, then let the first deadline pass (or create it with a past deadline via cast) → act 3
```

## Act 1 — "I buy in installments" (1 min)
UI section 1 → seller mints the demo asset, escrows it, price 100, 4 installments.
Point at the schedule: deposit **40 %** (newcomer). Say: *the asset is locked on Creditcoin; nobody — not
even us — holds a lockout button.*

## Act 2 — "I pay, and the installment validates itself" (3 min)
UI section 2 → **Pay deposit (permit, 1 tx)** on Sepolia. Then **Sign once → autopay the rest**: 3
EIP-3009 signatures, no more transactions from the buyer. Worker log shows `autopay … paid`, then
`pending proof`, then `settled 3 installment(s) … gas`.
Switch to section 3: status flips `Active → Completed`, asset owner = buyer.
Section 4: passport `honored = 4`, next deposit **15 %**. Say: *every line of this passport is an
inclusion proof; Credal does this declaratively, we do it trustlessly.*
Pre-paid installment (done 12 min earlier) is the one that lands live; the others are already green.

## Act 3 — "I don't pay, and the seller gets the asset back — nobody pressed anything" (1.5 min)
Order B, past its deadline + grace. Section 3 shows `overdue: default can be asserted` against the
**attested** height. Click **Declare default (anyone)** — permissionless, no oracle, the tutorial
does this `onlyOwner`. Status `DefaultAsserted`, cure window visible.
Say: *if the buyer had paid on time and the proof is late, that proof cures it — default is an
optimistic assertion, the proof is its fraud proof.* Then **Finalize default** (pre-aged order so the
window has elapsed): asset back to seller, passport `defaulted = 1`.

## Act 4 (optional, +1.5 min if the slot allows) — "the object can't be swapped either"
Order C, chip-backed asset. Show the seller's chip signing at listing (`attest-origin`), the same chip
signing again at a simulated handoff (`attest-delivery`) → bond returns to the seller, cryptographic
proof of no substitution. Then repeat with a *different* chip key on a second demo order → bond
slashed to the buyer instantly, no jury. Say: *the same trick that makes default optimistic — prove a
positive, never a negative — closes the one hole a payment proof can't: is this even the same object.*
Cut this act first if time runs short; acts 1-3 carry the pitch on their own.

## Numbers to say out loud (measured, README)
- 1 proof: 357 k gas. 3 proofs, 1 continuity proof: 176 k each (−51 %).
- Fresh proof 43.7 k at the precompile, aged ~85 k: ×2, flat after — freshness matters, batching matters more.
- 0/76 projects of season 1 ran the full verify cycle; 0/76 used batch.

## Closing line
*The default is the default state. The proof is what saves you. No oracle, no keeper, no liquidator —
and a product a non-technical person understands in 30 seconds.*
