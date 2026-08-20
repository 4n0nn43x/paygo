# PayGo — trustless cross-chain hire-purchase

**BUIDL CTC 2026 Fall** · Creditcoin × Attestcoin.

> The asset is escrowed on Creditcoin. Installments are paid in ERC20 on Ethereum.
> A payment only exists once proven by Attestcoin. Silence after grace = default, automatically.
> No price oracle, no keeper, no liquidator. Every function is permissionless.

## Layout

| Path | Chain | What |
|---|---|---|
| `contracts/PayGoRouter.sol` | Sepolia | stateless, 3 ways in — `payInstallment`, `payWithPermit` (EIP-2612), `payWithAuthorization` (EIP-3009 autopay) — one `InstallmentPaid` event out |
| `contracts/PayGoEscrow.sol` | Creditcoin | orders, `settle` (1..10 proofs, one continuity proof), `declareDefault` / `finalizeDefault`; deposit sized by the buyer's passport (40 % → 15 %) |
| `contracts/CreditPassport.sol` | Creditcoin | ERC-5192 soulbound record of payment facts, written and read back by the escrow |
| `contracts/Attestcoin.sol` | — | precompile interfaces 0x…0FD2 (BlockProver) / 0x…0fD3 (ChainInfo) |
| `contracts/Demo.sol` | — | `TestUSDC` (permit + EIP-3009), `DemoAsset` |
| `test/` | — | 22 tests: 5 security checks, state machine, batch, passport, permit/3009, real-proof fixture |
| `worker/settle.ts` | — | convenience relayer: autopay pre-signed authorizations + listen → wait attested → batch proof → `settle`; serves the checkout UI |
| `web/index.html` | — | single-page checkout: seller listing, 1-click deposit, sign-once autopay, live tracker, passport |
| `web/landing.html` | — | marketing landing — self-contained (open directly): hero with a schedule that lights up as each payment is proven, mechanism, measured proof, the 3 acts |
| `docs/` | — | `DEMO.md` (3-act stage script), `SUBMISSION.md` (technical submission), `AUDIT.md` |

## Run

```sh
npm i
forge test
```

## Deployed (CC3 testnet / Sepolia, 2026-08-19)

| Contract | Chain | Address |
|---|---|---|
| PayGoRouter | Sepolia | `0x42D5880d5Aa7490D90eF6842478D9d8Aa6D71474` |
| TestUSDC (permit + EIP-3009) | Sepolia | `0x278138aDe5bE8628fd81a5268Ff2C891FDbBE9F3` |
| PayGoEscrow (chainKey 1, grace 2000, cure 240) | Creditcoin CC3 | `0x76148A747fCdD26819e0329a9633E24cBE2a53b4` |
| DemoAsset | Creditcoin CC3 | `0xbEcf8967f7fCe9c4dB9CE47E4c97479A21033D75` |
| CreditPassport (auto-deployed by escrow) | Creditcoin CC3 | `0xBB52fDa813AC1041a0c05d6049Da41d9797Ea767` |

v2 (post-audit) addresses. Same deployer nonce on both chains kept Router/Escrow aligned across the earlier deploy; the escrow check `topics[1] == address(this)` still namespaces orders per deployment.

## Demo (CLI)

```sh
cp .env.example .env            # fill key + addresses
sh script/deploy.sh             # once
sh script/demo.sh order         # act 1: seller escrows asset, 4 installments
sh script/demo.sh pay 1 0       # act 2: buyer pays on Sepolia…
npm run worker                  #        …worker proves it ~10 min later, escrow settles
sh script/demo.sh default 1     # act 3: silence after grace → anyone asserts default
sh script/demo.sh finalize 1    #        cure window passes → asset back to seller
```

## Measured on CC3 testnet (real proofs, not estimates)

| Scenario | Tx | Gas | Per installment |
|---|---|---|---|
| 1 fresh proof, first installment of order 1 | [`0x818e…2469`](https://explorer.cc3-testnet.creditcoin.network/tx/0x818e27e885c5c8ceb754231548728e7157f7043d82a99300bf7674fd66d92469) | 357 476 | 357 476 |
| 3 proofs, one continuity proof (installments 1-3, order 1 → **Completed**, asset transferred to buyer) | [`0x8b12…7847`](https://explorer.cc3-testnet.creditcoin.network/tx/0x8b123684246c82263336be169f0b5830ebdfdf6a467801e69f9857adddc47847) | 528 416 | **176 139** (−51 %) |
| 4 proofs, one continuity proof (v2, order 1 → **Completed**) | [`0x2c0d…c4ef`](https://explorer.cc3-testnet.creditcoin.network/tx/0x2c0ddd628c85a57555c35e3095f1664a3aec6a574c68fa4a89a6596e0685c4ef) | 639 646 | **159 912** (−55 %) |

Full lifecycle proven end-to-end on the v2 (post-audit) deployment:
- **Order 1 (happy path)**: created → 4 installments paid on Sepolia → all four proven & settled in **one** continuity proof → `Completed`, `DemoAsset #1` transferred to the buyer, passport `honored = 4` → next `depositBps = 1500` (15 %).
- **Order 2 (default path)**: deadline already past → `declareDefault` accepted against the ChainInfo attested height → `DefaultAsserted` → cure window elapsed → `finalizeDefault` → `Defaulted`, `DemoAsset #2` returned to the seller, passport `defaulted = 1`.
Nobody pressed a liquidation button; the default is the default state and a proof is what saves you.

### Proof freshness (raw precompile `verify`, `node script/gas-probe.mjs`, attested height 11 524 740)

| age | continuity roots | verify() gas |
|---|---|---|
| fresh (~10 min) | 1 | 43 748 |
| +6 h | 61 | 85 665 |
| +24 h | 62 | 84 284 |
| +7 d | 62 | 86 127 |

Measured, not assumed: an aged proof costs ~2× a fresh one (the prover anchors on the nearest checkpoint, ~60 roots), and it stays flat after that. Batching (−51 % measured) is the bigger lever; freshness is the second.
