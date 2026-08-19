# PayGo — trustless cross-chain hire-purchase

**BUIDL CTC 2026 Fall** · Creditcoin × Attestcoin.

> The asset is escrowed on Creditcoin. Installments are paid in ERC20 on Ethereum.
> A payment only exists once proven by Attestcoin. Silence after grace = default, automatically.
> No price oracle, no keeper, no liquidator. Every function is permissionless.

## Layout

| Path | Chain | What |
|---|---|---|
| `contracts/PayGoRouter.sol` | Sepolia | stateless: `transferFrom` + `InstallmentPaid` event |
| `contracts/PayGoEscrow.sol` | Creditcoin | orders, `settle` (1..10 proofs, one continuity proof), `declareDefault` / `finalizeDefault`, passport counters |
| `contracts/Attestcoin.sol` | — | precompile interfaces 0x…0FD2 (BlockProver) / 0x…0fD3 (ChainInfo) |
| `contracts/Demo.sol` | — | `TestUSDC`, `DemoAsset` for the demo |
| `test/` | — | 5 security checks + state machine, precompiles mocked with `vm.etch` |
| `worker/settle.ts` | — | convenience relayer: listen → wait attested → batch proof → `settle` |

## Run

```sh
npm i
forge test
```

## Deployed (CC3 testnet / Sepolia, 2026-08-19)

| Contract | Chain | Address |
|---|---|---|
| PayGoRouter | Sepolia | `0xB4375c5CBe4f1395ff673574144e64A995d147C7` |
| TestUSDC | Sepolia | `0x73B9dEAA040643c849D7adE5AEad1cF674013F34` |
| PayGoEscrow (chainKey 1, grace 2000 ETH blocks, cure 240 CTC blocks) | Creditcoin CC3 | `0xB4375c5CBe4f1395ff673574144e64A995d147C7` |
| DemoAsset | Creditcoin CC3 | `0x73B9dEAA040643c849D7adE5AEad1cF674013F34` |

Same deployer nonce on both chains → same addresses; the escrow check `topics[1] == address(this)` still namespaces orders per deployment.

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
