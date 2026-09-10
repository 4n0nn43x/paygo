# Building and running PayGo

How to build, deploy, run and verify PayGo from a clean checkout, and what the Attestcoin Protocol
integration actually does at each step. [`ARCHITECTURE.md`](ARCHITECTURE.md) covers why the design is
shaped this way; the [README](../README.md) covers what PayGo is. This document covers the setup.

Everything below was run against Creditcoin CC3 testnet and Ethereum Sepolia. No step is theoretical.

## Prerequisites

| Requirement | Why |
|---|---|
| [Foundry](https://getfoundry.sh) | contracts, tests, deployment, and `cast` for the demo script |
| Node 22+ | the relayer (`tsx`) and the Vite web client |
| A funded key on **both** chains | tCTC on CC3 testnet for gas and custody bonds, Sepolia ETH for gas |
| A second address | `createOrder` rejects `buyer == msg.sender`, so a demo needs two parties |

tCTC comes from the Creditcoin Discord faucet, which has a human in the loop. Request it before you
need it. Sepolia ETH comes from any public faucet. The test payment token is minted by the contracts
themselves, so no faucet is needed for it.

## Environment

Copy `.env.example` to `.env` and fill it in. Four values are protocol constants, the rest are
deployment outputs:

```sh
SOURCE_CHAIN_KEY=1                                             # Sepolia, per the Attestcoin Protocol
PROOF_BUILDER_URL=https://prover.cc3-testnet.creditcoin.network
CREDITCOIN_RPC_URL=https://rpc.cc3-testnet.creditcoin.network
SOURCE_CHAIN_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
```

`SOURCE_CHAIN_KEY` is the Attestcoin Protocol's identifier for the source chain, **not** an EVM chain
id. On CC3 testnet, Sepolia is `1` and Ethereum mainnet is `3`; on CC3 mainnet, Ethereum mainnet is
`1`. It is baked into the escrow at construction and is never a user-supplied parameter, because a
caller who could choose the chain key could choose which chain to be believed about.

Both RPC URLs are handed to the browser by `GET /state` and pinned in the client's CSP. Use public
endpoints. A URL carrying an API key would be published to every visitor.

## Build and test

```sh
npm i
forge build
forge test          # 59 tests
```

`RealProof.t.sol` replays a proof captured from CC3 testnet and needs `test/fixtures.json`; CI
excludes it with `--no-match-path`. Every other test runs against `MockNativeQueryVerifier`, because
a real proof takes minutes to become available and a test suite cannot wait for attestation.

The web client builds separately:

```sh
npm run build:web   # web/app -> web/dist
```

## Deploy

```sh
sh script/deploy.sh
```

It deploys `PayGoRouter`, `CustodyRouter` and `TestUSDC` on Sepolia, then `DemoAsset` and
`PayGoEscrow` on Creditcoin, and prints the lines to paste back into `.env`.

Two things in that script matter more than they look:

**`EvmV1Decoder` must be linked at deploy time.** It is the Attestcoin Protocol's receipt and log
decoding library, deployed once per network, and Solidity external libraries are not embedded in the
bytecode. Forgetting `--libraries` produces a contract that deploys fine and reverts on the first
proof. On CC3 testnet the library is at `0x731c345d79Fb8BbDC541f9DF3b6317585F849F9f`.

**The asset and payment token allowlists are constructor arguments.** `DemoAsset` and `TestUSDC` are
deployed before the escrow because the escrow takes their addresses and accepts nothing else. There
is no setter, so widening an allowlist means deploying again. That is deliberate: a seller-supplied
ERC-721 whose `transferFrom` reverts on release, or an ERC-20 with an unbounded `mint`, are both
attack surfaces the escrow refuses to inherit.

## Run

```sh
npm run worker      # relayer + web client on :8787
```

One process does four things: submits pre-signed EIP-3009 authorizations when they come due, watches
`InstallmentPaid` on the Router, watches `PossessionAttested` on the CustodyRouter, and serves the
built client with a `GET /state` and `POST /authorizations` API.

The relayer is a convenience, not a trust assumption. `settle`, `settleCustody`, `declareDefault`
and `finalizeDefault` are permissionless: a buyer who does not trust it can submit the identical
proof themselves.

By default it settles each payment as soon as its source height is attested. Set `BATCH_WAIT=1` to
hold a window until it is full or roughly 1000 blocks old: cheaper per installment, hours slower.
That flag is what produced the batch rows in the README's gas table.

## The proof pipeline, step by step

This is the Attestcoin Protocol integration, from a payment on Ethereum to a state change on
Creditcoin. Each step names the code that performs it.

1. **The payment emits a dedicated event.** `PayGoRouter` is stateless and does one thing:
   `transferFrom`, then `emit InstallmentPaid(escrow, orderId, installmentNo, payer, payee, token,
   amount)`. A single source contract, one unambiguous event per query kind, and every field the
   escrow will need inside the event. Proving against a shared `Transfer` signature was considered
   and rejected: there is no field to bind an order to a payment.
2. **The relayer waits for attestation.** `proofProvider.waitUntilHeightAttested(chainKey, height)`
   from `@gluwa/usc-sdk@0.18.0`. Measured latency on CC3 testnet is roughly 20 Sepolia blocks, so a
   few minutes; budget ten before a proof is usable end to end.
3. **It builds one proof for the batch.** `ProofBuilder.getBatchProof(txHashes)` returns per
   transaction Merkle proofs plus one shared continuity proof.
4. **It dry-runs the call.** `escrow.settle.staticCall(...)` before sending, then `estimateGas`
   rather than a fixed limit. One invalid proof reverts an entire batch, and a large receipt runs out
   of gas under a fixed cap. Both were observed, not predicted.
5. **The escrow verifies and applies, in one transaction.** `PayGoEscrow.settle` calls
   `verifyAndEmit` on the BlockProver precompile `0x…0FD2`, decodes the proven receipt with
   `EvmV1Decoder`, runs the five checks, then marks the installment paid and writes the fact to the
   soulbound passport. Verification and business logic are the same transaction: there is no
   intermediate oracle state anyone could tamper with.

`declareDefault` uses the other half of the protocol: it reads the latest attested source height from
the ChainInfo precompile `0x…0fD3` and compares it against `deadline + GRACE`. That is what lets
anyone assert a default with no oracle and no privileged caller.

## Drive a full lifecycle

`script/demo.sh` runs the whole thing from the command line.

```sh
sh script/demo.sh order            # escrow an asset, buyer = $BUYER, 4 installments
sh script/demo.sh pay 1 0          # pay the deposit on Sepolia
sh script/demo.sh show 1           # order state
sh script/demo.sh passport         # the buyer's record and the deposit rule it produces
sh script/demo.sh default 1        # assert a default (needs attested height > deadline + GRACE)
sh script/demo.sh finalize 1       # after the cure window
sh script/demo.sh claim 1          # buyer pulls the asset after Completed
sh script/demo.sh withdraw 1       # seller pulls it back after Defaulted
```

Three timings govern what you can demonstrate and when:

| Wait | Length | Set by |
|---|---|---|
| Payment to usable proof | a few minutes | attestation latency |
| Deadline to assertable default | `GRACE = 2000` Ethereum blocks, about 6 h 40 | escrow constructor |
| Assertion to finalisable default | `CURE_WINDOW = 240` Creditcoin blocks, about 1 h at 15 s per block | escrow constructor |

An order created now becomes overdue ten to thirteen hours later: `demo.sh` places the first
deadline two epochs ahead of the current Sepolia head, and `createOrder` accepts only epoch-aligned
schedules (`firstDeadline % EPOCH == 0 && interval % EPOCH == 0`), which is what makes payments from
unrelated orders land in the same provable window. Plan a demonstration of the default path a day
in advance.

## Reproduce the measurements

```sh
node script/gas-probe.mjs
```

It calls `verify()` at the precompile against proofs of different ages and prints the gas each one
costs. The README's freshness table comes from this script; its transaction links come from real
`settle` calls on CC3 testnet.

## Continuous integration

`.github/workflows/ci.yml` runs on every push: `forge test`, gitleaks over the full history, Semgrep
with explicit rulesets, a Docker build scanned by Trivy, and zizmor over the workflows themselves.
Every scanner image is pinned by digest and every action by commit SHA, so a compromised upstream tag
cannot change what runs.

## Deploying the service

`compose.yaml` runs the relayer behind Caddy, which terminates TLS. The relayer is never published on
the host, only reachable on the internal network. Its container has a read-only root filesystem, no
capabilities, `no-new-privileges`, and a named volume for its state file, so a restart resumes from
the last processed block instead of replaying or skipping. `npm` is removed from the runtime image:
it is never called after build, and its bundled dependencies carried vulnerabilities that had nothing
to do with this project.

## Traps worth knowing

Each of these cost real time and each is now covered by a test or a guard.

- **The precompile has no replay protection.** The same proof verifies twice. The nullifier is
  written before any other work, keyed on `(chainKey, height, txIndex)`.
- **`verifyAndEmit` reverts on an invalid proof and never returns false.** Any code expecting a
  boolean failure branch is dead code.
- **The precompile does not check `receiptStatus`.** A reverted payment is perfectly provable, and
  without the check it would settle an installment.
- **Log lookup filters on the event signature alone.** Any contract can emit `InstallmentPaid`, so
  the emitter is pinned to the known Router and `topics[1]` to the escrow instance.
- **A non-applicable log must be skipped, not reverted on.** Otherwise a griefer co-locates a poison
  log with a victim's payment and makes it permanently unsettleable.
- **`cast` annotates large numbers in scientific notation.** Parsing its output naively overpaid
  installments and inflated passport volume before `demo.sh` learned to strip the annotation.

Security reviews, findings and accepted residual risks: [`AUDIT.md`](AUDIT.md).
