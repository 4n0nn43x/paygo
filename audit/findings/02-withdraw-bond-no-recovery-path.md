# 02 — `withdrawBond` has no recovery path when the resolved recipient can't accept a bare value transfer

**Severity: Medium** (two refuters disagree on framing — see below; this report takes the more conservative reading). **Status: FIXED.** Regression:
`test/ZZBondLockPoC.t.sol` (`test_withdrawBond_resolvesCleanly_onlyThePullToNonPayableFails`),
`test/PayGoEscrow.t.sol` (`test_claimBond_nonPayableRecipientDoesNotBrickResolution`).

## Where
`contracts/PayGoEscrow.sol:294-309`:
```solidity
function withdrawBond(uint256 id) external {
    Order storage o = orders[id];
    address to = bondRecipient[id];
    if (to == address(0) && o.status == Status.Completed && !o.custodyDisputed
        && o.completedAt != 0 && block.number > o.completedAt + CUSTODY_WINDOW) {
        to = o.seller;
    }
    require(to != address(0), "not resolved");
    uint256 amount = custodyBond[id];
    require(amount > 0, "no bond");
    custodyBond[id] = 0;
    bondRecipient[id] = to;
    (bool ok, ) = to.call{value: amount}("");   // <-- unconditional require(ok) below
    require(ok, "transfer failed");
    emit BondWithdrawn(id, to, amount);
}
```

## The bug
State (`custodyBond[id] = 0; bondRecipient[id] = to;`) is written before the external `.call`, which is correct CEI ordering — but `require(ok, "transfer failed")` after the call means a failed transfer reverts the **whole** transaction, including those preceding writes. `to` is deterministically re-derived as the same address on every call (either the already-resolved `bondRecipient[id]`, or the timeout-default `o.seller`), so if that address is a contract with no payable `receive`/`fallback`, every call to `withdrawBond(id)` — by anyone, forever — reverts identically. There is no admin, no sweep, no re-target-to-a-different-address function anywhere in the contract.

## Proof
`test/ZZBondLockPoC.t.sol` — `forge test --match-path test/ZZBondLockPoC.t.sol -vvv`:
```
[PASS] test_withdrawBond_permanentlyLocksWhenRecipientCannotReceiveValue() (gas: 288939)
```
Recipient is a minimal, non-hostile stand-in (`contract NonPayableBuyer {}` — no `receive`, no malice, just the default state of not adding one) — not a contrived attacker contract. This matters for how realistic the trigger is: it's the mundane absence of a payable fallback, not deliberate griefing.

## Two readings, both grounded in the code — reported honestly rather than picking one
- **Reachability/guards refuter**: confirms this is genuinely reachable with zero attacker action, notes the framing "any smart-contract wallet" is **overstated** — standard Gnosis Safe and ERC-4337 reference accounts both implement a payable fallback and would NOT trigger this. The honest victim class is narrower: bespoke multisigs, vault/treasury contracts, or custom account contracts that specifically lack a `receive`/payable `fallback`. Real, but not "any smart contract wallet."
- **Impact refuter**: confirms the mechanism but argues for a lower severity than "funds gone forever" — the CTC is never burned, it sits correctly earmarked in the contract's own balance (`custodyBond[id]` and `bondRecipient[id]` both survive the revert unchanged, verified directly in the PoC), and **a plain retry of `withdrawBond(id)` succeeds automatically** the moment the recipient address becomes able to receive value (redeployed, upgraded to add a `receive()`, etc.) — no code change needed, since the "stuck" and "resolved" states share the same code path. This directly matches `docs/AUDIT.md`'s own existing LOW-2 description of the *asset*-side pull pattern (`claimAsset`/`withdrawAsset`), and in fact `docs/AUDIT.md`'s custody section already predicted this exact scenario in near-identical words ("the bond is simply retrievable later once the recipient can accept it") — this PoC shows that's only true if the recipient *can* later become payable, which for a genuinely immutable, non-upgradeable contract with no `receive()`, it can't.

Net: the mechanism is real and un-disputed. What's disputed is whether "permanent, no recovery" (this session's own `docs/AUDIT.md` framing, now shown incomplete) or "same category as the already-accepted LOW-2, just needing a more precise caveat" is the fairer severity. This report rates it **Medium**: real, no fund-safety violation in the sense of theft, self-healing in the common case (payable recipient), but a genuine gap for the subset of recipients that can never become payable, with no code-level way to redirect to a different address even when everyone agrees who *should* receive it.

## Fix applied
Split `withdrawBond` into two functions (`contracts/PayGoEscrow.sol`): `withdrawBond(id)` now only *resolves* — no external call, so it can never fail on a bad recipient — and credits a pooled `claimableBond[to]` balance; a new `claimBond()`, callable only by the recipient itself (`msg.sender`), does the actual `.call{value}` payout. Per-order bookkeeping (`custodyBond`/`bondRecipient`) now always finalizes; only the final pull can fail, and only for that one recipient, never cascading into other orders' resolution. This does not (and structurally cannot) make a truly immutable, non-payable contract able to receive ETH — that remains a property of the recipient's own code — but it removes the part of the bug that was actually PayGo's to fix: per-order state getting permanently wedged. A WETH-wrap fallback (documented as a future option, not implemented) would close the remaining gap for good.
