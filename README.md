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
