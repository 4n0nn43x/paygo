# PayGo — trustless cross-chain hire-purchase

**BUIDL CTC 2026 Fall** · Creditcoin × Attestcoin.

> The asset is escrowed on Creditcoin. Installments are paid in ERC20 on Ethereum.
> A payment only exists once proven by Attestcoin. Silence after grace = default, automatically.
> No price oracle, no keeper, no liquidator. Every function is permissionless.

## Layout

| Path | Chain | What |
|---|---|---|
| `contracts/PayGoRouter.sol` | Sepolia | stateless, 3 ways in — `payInstallment`, `payWithPermit` (EIP-2612), `payWithAuthorization` (EIP-3009 autopay) — one `InstallmentPaid` event out |
| `contracts/CustodyRouter.sol` | Sepolia | stateless, Proof-of-Custody: a chip (EIP-5791) signs at listing (Origin) and delivery — `attestPossession` verifies and emits `PossessionAttested` |
| `contracts/PayGoEscrow.sol` | Creditcoin | orders (asset contract must be allowlisted at deploy time), `settle` (1..10 proofs, one continuity proof), `settleCustody` (same 5 checks, for chip attestations), `declareDefault` / `finalizeDefault`, `claimAsset` / `withdrawAsset` / `withdrawBond` (pull, not pushed — isolates a hostile asset's `transferFrom` or a reverting bond payout from the settle batch); deposit sized by the buyer's passport (40 % → 15 %) |
| `contracts/CreditPassport.sol` | Creditcoin | ERC-5192 soulbound record of payment facts, written and read back by the escrow |
| `contracts/SellerPassport.sol` | Creditcoin | ERC-5192 soulbound record of custody facts (Proof-of-Custody's mirror of CreditPassport) — `waivesBond` gates whether a seller must post a custody stake |
| `contracts/Attestcoin.sol` | — | precompile interfaces 0x…0FD2 (BlockProver) / 0x…0fD3 (ChainInfo) |
| `contracts/Demo.sol` | — | `TestUSDC` (permit + EIP-3009), `DemoAsset` |
| `test/` | — | 36 tests: 5 security checks, state machine, batch, passport, permit/3009, real-proof fixture, asset allowlist + pull-pattern, Proof-of-Custody (match/mismatch/timeout) |
| `worker/settle.ts` | — | convenience relayer: autopay pre-signed authorizations + listen → wait attested → batch proof → `settle` / `settleCustody`; serves the checkout UI |
| `web/app/` | — | Vite + React + TypeScript source. Two entries, built to `web/dist/` (`npm run build:web`, gitignored, served by the worker): landing (`/`) and the checkout dashboard (`/dashboard/` — seller listing + custody bond, 1-click deposit, sign-once autopay, live tracker, passport, Proof-of-Custody chip attestation). No router — two static Vite build inputs, same shape as the two HTML files this replaced |
| `docs/` | — | `DEMO.md` (stage script), `SUBMISSION.md` (technical submission), `AUDIT.md`; see also [`../docs/08-proof-of-custody.md`](../docs/08-proof-of-custody.md) for the full Proof-of-Custody spec |

## Run

```sh
npm i
forge test
npm run build:web   # builds web/app -> web/dist, served by the worker at / (landing) and /dashboard/ (checkout)
```

## Deployed (CC3 testnet / Sepolia, 2026-08-31)

| Contract | Chain | Address |
|---|---|---|
| PayGoRouter | Sepolia | `0x912Fd5a73AA2d1b56f14F2e8B1cC17F2Cfc7327F` |
| CustodyRouter | Sepolia | `0x9AFa2dFAe36380D45524a0Fd520FeB806CAE38c5` |
| TestUSDC (permit + EIP-3009) | Sepolia | `0x3b332374E1F564b57d3A6f7dDe33e13030BD8895` |
| PayGoEscrow (chainKey 1, grace 2000, cure 240, custody window 240) | Creditcoin CC3 | `0xD0B9c4c67c542e18B7EA556BbbAE3E0Eb2637878` |
| DemoAsset (mint + mintWithMeta, real tokenURI) | Creditcoin CC3 | `0xCAb49452967b2d9671cB75BFb947E715B0B6cFB1` |
| CreditPassport (auto-deployed by escrow) | Creditcoin CC3 | `0x675d81526DF8ae5F7654F0949B8Cf7Ea6Aa668A3` |
| SellerPassport (auto-deployed by escrow) | Creditcoin CC3 | `0xA30C9538C168CB6A54908E31E52BeB9Ec4930aD4` |

**v4** — adds real on-chain tokenURI metadata to `DemoAsset` (`mintWithMeta`: name/description/image,
JSON-escaped; plain `mint` unchanged, zero breaking change to any existing caller). Everything from v3
(post-security-pass: asset/payToken allowlists, the pull-pattern `claimAsset`/`withdrawAsset`/
`withdrawBond`+`claimBond` split, Proof-of-Custody, the three `audit/findings/` fixes — see
`docs/AUDIT.md`) carries forward unchanged.
Verified on-chain post-deploy: constructor immutables, both allowlists, the two child passport
contracts, and `DemoAsset`'s new `tokenURI` (correctly reverts `ERC721NonexistentToken` for an unminted
id — matches `test/DemoAsset.t.sol`). Same deployer nonce ordering (Router/CustodyRouter/TestUSDC on
Sepolia, then DemoAsset/Escrow on Creditcoin) as prior deploys; the escrow check
`topics[1] == address(this)` still namespaces orders per deployment — orders from earlier deployments
do not carry over to v4's contract state.

## Demo (CLI)

```sh
cp .env.example .env            # fill key + addresses
sh script/deploy.sh             # once
sh script/demo.sh order         # act 1: seller escrows asset, 4 installments
sh script/demo.sh pay 1 0       # act 2: buyer pays on Sepolia…
npm run worker                  #        …worker proves it ~10 min later, escrow settles
sh script/demo.sh default 1     # act 3: silence after grace → anyone asserts default
sh script/demo.sh finalize 1    #        cure window passes → order Defaulted
sh script/demo.sh withdraw 1    #        seller pulls the asset back (claimAsset for the buyer on completion)

# act 4 (Proof-of-Custody, order 2 e.g.): a chip signs at listing, then again at delivery
# (each attestation's submitter must be the order's seller/buyer respectively — pass their key as
# the optional 3rd arg, or run as $PK if you created the order as yourself)
sh script/demo.sh attest-origin   2 0xCHIP_PRIVATE_KEY 0xSELLER_KEY   # seller's chip, at listing
sh script/demo.sh attest-delivery 2 0xCHIP_PRIVATE_KEY 0xBUYER_KEY    # same chip at handoff → bond resolves to seller
sh script/demo.sh withdraw-bond 2                                     # resolve into the claimable pool (or a DIFFERENT chip key → resolves to buyer)
sh script/demo.sh claim-bond 0xSELLER_KEY                             # (or 0xBUYER_KEY, whoever it resolved to) pull the payout
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
