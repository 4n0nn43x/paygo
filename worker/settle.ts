// PayGo settle worker — a convenience relayer, nothing more: `settle` is permissionless,
// anyone (the buyer included) can submit the same proofs by hand.
//   listen InstallmentPaid on Sepolia → wait until attested → one batch proof per
//   ≤10 txs / ≤1000-block window → PayGoEscrow.settle on Creditcoin.
import 'dotenv/config';
import { Contract, JsonRpcProvider, Wallet } from 'ethers';
import { proofProvider } from '@gluwa/usc-sdk';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const env = (k: string) => { const v = process.env[k]; if (!v) throw new Error(`missing env ${k}`); return v; };
const CHAIN_KEY = Number(env('SOURCE_CHAIN_KEY'));
const MAX_BATCH = 10, MAX_RANGE = 1000, POLL_MS = 15_000;
const STATE_FILE = process.env.WORKER_STATE ?? 'worker/state.json';

const ROUTER_ABI = ['event InstallmentPaid(address indexed escrow,uint256 indexed orderId,uint8 installmentNo,address payer,address payee,address token,uint256 amount)'];
const ESCROW_ABI = ['function settle(uint64[] heights,bytes[] txs,(bytes32 root,(bytes32 hash,bool isLeft)[] siblings)[] proofs,(bytes32 lowerEndpointDigest,bytes32[] roots) continuity)'];

const sepolia = new JsonRpcProvider(env('SOURCE_CHAIN_RPC_URL'));
const cc = new JsonRpcProvider(env('CREDITCOIN_RPC_URL'));
const wallet = new Wallet(env('CREDITCOIN_WALLET_PRIVATE_KEY'), cc);
const router = new Contract(env('ROUTER_ADDRESS'), ROUTER_ABI, sepolia);
const escrow = new Contract(env('ESCROW_ADDRESS'), ESCROW_ABI, wallet);
const prover = new proofProvider.service.ProofBuilder(CHAIN_KEY, env('PROOF_BUILDER_URL'));

type Pending = { hash: string; height: number };
const state: { fromBlock: number; pending: Pending[]; done: string[] } = existsSync(STATE_FILE)
  ? JSON.parse(readFileSync(STATE_FILE, 'utf8'))
  : { fromBlock: Number(process.env.START_BLOCK ?? 0), pending: [], done: [] };
const save = () => writeFileSync(STATE_FILE, JSON.stringify(state, null, 1));

async function collect() {
  const head = await sepolia.getBlockNumber();
  if (state.fromBlock === 0) state.fromBlock = head;
  if (head < state.fromBlock) return;
  const to = Math.min(head, state.fromBlock + 5000); // ponytail: RPC range cap, raise if your RPC allows
  const logs = await router.queryFilter('InstallmentPaid', state.fromBlock, to);
  for (const l of logs) {
    if (!state.done.includes(l.transactionHash) && !state.pending.some(p => p.hash === l.transactionHash)) {
      state.pending.push({ hash: l.transactionHash, height: l.blockNumber });
      console.log(`+ payment ${l.transactionHash} @${l.blockNumber}`);
    }
  }
  state.fromBlock = to + 1;
  save();
}

async function settleBatch(batch: Pending[]) {
  const top = Math.max(...batch.map(p => p.height));
  console.log(`waiting attestation of height ${top} (${batch.length} tx)…`);
  await prover.waitUntilHeightAttested(CHAIN_KEY, top, POLL_MS, 30 * 60_000);
  const res = await prover.getBatchProof(batch.map(p => p.hash));
  if (!res.success || !res.data) throw new Error(res.error);
  const heights: number[] = [], txs: string[] = [], proofs: any[] = [];
  for (const [h, m] of res.data.merkleProofs) for (const [, e] of m) { heights.push(h); txs.push(e.txBytes); proofs.push(e.merkleProof); }
  const args = [heights, txs, proofs, res.data.continuityProof];
  await escrow.settle.staticCall(...args);          // one rotten proof would revert the whole batch
  const tx = await escrow.settle(...args, { gasLimit: 2_000_000 });
  console.log(`settle ${heights.length} tx → ${tx.hash}`);
  const rc = await tx.wait();
  console.log(`  mined, gas=${rc.gasUsed} (${(Number(rc.gasUsed) / heights.length).toFixed(0)} per installment)`);
  state.done.push(...batch.map(p => p.hash));
  state.pending = state.pending.filter(p => !batch.includes(p));
  save();
}

async function loop() {
  for (;;) {
    try {
      await collect();
      if (state.pending.length) {
        const sorted = [...state.pending].sort((a, b) => a.height - b.height);
        const lo = sorted[0].height;
        const batch = sorted.filter(p => p.height - lo < MAX_RANGE).slice(0, MAX_BATCH);
        // settle when the window is full, or when the oldest has waited ~one window; otherwise let it fill
        const head = await sepolia.getBlockNumber();
        if (batch.length === MAX_BATCH || head - lo >= MAX_RANGE || process.env.SETTLE_NOW) {
          try { await settleBatch(batch); }
          catch (e: any) {
            console.error('batch failed:', e.shortMessage ?? e.message);
            if (batch.length > 1) for (const p of batch) { try { await settleBatch([p]); } catch (e2: any) { console.error(`  ${p.hash}: ${e2.shortMessage ?? e2.message}`); } }
          }
        }
      }
    } catch (e: any) { console.error(e.shortMessage ?? e.message); }
    await new Promise(r => setTimeout(r, POLL_MS));
  }
}
loop();
