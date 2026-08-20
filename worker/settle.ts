// PayGo worker — a convenience relayer, nothing more: `settle` is permissionless, anyone (the buyer
// included) can submit the same proofs by hand. It does three things:
//   1. autopay: submits the EIP-3009 authorizations the buyer pre-signed at checkout, when they become valid
//   2. settle:  listen InstallmentPaid on Sepolia → wait until attested → one batch proof per ≤10 txs /
//               ≤1000-block window → PayGoEscrow.settle on Creditcoin
//   3. serves web/index.html + a tiny JSON API (POST /authorizations, GET /state) for the checkout
import 'dotenv/config';
import { Contract, JsonRpcProvider, Wallet } from 'ethers';
import { proofProvider } from '@gluwa/usc-sdk';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { createServer } from 'node:http';

const env = (k: string) => { const v = process.env[k]; if (!v) throw new Error(`missing env ${k}`); return v; };
const CHAIN_KEY = Number(env('SOURCE_CHAIN_KEY'));
const MAX_BATCH = 10, MAX_RANGE = 1000, POLL_MS = 15_000;
const STATE_FILE = process.env.WORKER_STATE ?? 'worker/state.json';
const PORT = Number(process.env.PORT ?? 8787);

const ROUTER_ABI = [
  'event InstallmentPaid(address indexed escrow,uint256 indexed orderId,uint8 installmentNo,address payer,address payee,address token,uint256 amount)',
  'function payWithAuthorization(address escrow,uint256 orderId,uint8 installmentNo,address token,address payee,uint256 amount,(address from,uint256 validAfter,uint256 validBefore,uint8 v,bytes32 r,bytes32 s) a)',
];
const ESCROW_ABI = ['function settle(uint64[] heights,bytes[] txs,(bytes32 root,(bytes32 hash,bool isLeft)[] siblings)[] proofs,(bytes32 lowerEndpointDigest,bytes32[] roots) continuity)'];

const sepolia = new JsonRpcProvider(env('SOURCE_CHAIN_RPC_URL'));
const cc = new JsonRpcProvider(env('CREDITCOIN_RPC_URL'));
const ccWallet = new Wallet(env('CREDITCOIN_WALLET_PRIVATE_KEY'), cc);
const sepWallet = new Wallet(env('CREDITCOIN_WALLET_PRIVATE_KEY'), sepolia);
const router = new Contract(env('ROUTER_ADDRESS'), ROUTER_ABI, sepWallet);
const escrow = new Contract(env('ESCROW_ADDRESS'), ESCROW_ABI, ccWallet);
const prover = new proofProvider.service.ProofBuilder(CHAIN_KEY, env('PROOF_BUILDER_URL'));

type Pending = { hash: string; height: number };
type Auth = { orderId: string; installmentNo: number; token: string; payee: string; amount: string;
  from: string; validAfter: number; validBefore: number; v: number; r: string; s: string; txHash?: string; error?: string };
const state: { fromBlock: number; pending: Pending[]; done: string[]; autopay: Auth[]; settles: { tx: string; count: number; gas: string }[] } = existsSync(STATE_FILE)
  ? { autopay: [], settles: [], ...JSON.parse(readFileSync(STATE_FILE, 'utf8')) }
  : { fromBlock: Number(process.env.START_BLOCK ?? 0), pending: [], done: [], autopay: [], settles: [] };
const save = () => writeFileSync(STATE_FILE, JSON.stringify(state, null, 1));

// ---- 1. autopay
async function autopay() {
  const now = Math.floor(Date.now() / 1000);
  for (const a of state.autopay) {
    if (a.txHash || a.error || a.validAfter >= now) continue;
    if (a.validBefore <= now) { a.error = 'expired'; save(); continue; }
    try {
      const tx = await router.payWithAuthorization(env('ESCROW_ADDRESS'), a.orderId, a.installmentNo, a.token, a.payee, a.amount,
        { from: a.from, validAfter: a.validAfter, validBefore: a.validBefore, v: a.v, r: a.r, s: a.s });
      a.txHash = tx.hash; save();
      console.log(`autopay order ${a.orderId} #${a.installmentNo} → ${tx.hash}`);
      await tx.wait();
    } catch (e: any) { a.error = e.shortMessage ?? e.message; save(); console.error('autopay failed:', a.error); }
  }
}

// ---- 2. settle
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
  state.settles.push({ tx: tx.hash, count: heights.length, gas: rc.gasUsed.toString() });
  state.done.push(...batch.map(p => p.hash));
  state.pending = state.pending.filter(p => !batch.includes(p));
  save();
}

async function settleLoop() {
  if (!state.pending.length) return;
  const sorted = [...state.pending].sort((a, b) => a.height - b.height);
  const lo = sorted[0].height;
  const batch = sorted.filter(p => p.height - lo < MAX_RANGE).slice(0, MAX_BATCH);
  // settle when the window is full, or when the oldest has waited ~one window; otherwise let it fill
  const head = await sepolia.getBlockNumber();
  if (!(batch.length === MAX_BATCH || head - lo >= MAX_RANGE || process.env.SETTLE_NOW)) return;
  try { await settleBatch(batch); }
  catch (e: any) {
    console.error('batch failed:', e.shortMessage ?? e.message);
    if (batch.length > 1) for (const p of batch) { try { await settleBatch([p]); } catch (e2: any) { console.error(`  ${p.hash}: ${e2.shortMessage ?? e2.message}`); } }
  }
}

// ---- 3. checkout UI + API
createServer((req, res) => {
  const json = (code: number, body: unknown) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
  if (req.method === 'GET' && req.url === '/state') return json(200, {
    router: env('ROUTER_ADDRESS'), escrow: env('ESCROW_ADDRESS'), usdc: process.env.USDC_ADDRESS, asset: process.env.ASSET_ADDRESS,
    chainKey: CHAIN_KEY, sepoliaRpc: env('SOURCE_CHAIN_RPC_URL'), ccRpc: env('CREDITCOIN_RPC_URL'),
    pending: state.pending, autopay: state.autopay, settles: state.settles, done: state.done.length,
  });
  if (req.method === 'POST' && req.url === '/authorizations') {
    let body = ''; let tooBig = false;
    req.on('data', c => { body += c; if (body.length > 64_000) { tooBig = true; req.destroy(); } });
    req.on('end', () => {
      if (tooBig) return json(413, { error: 'too large' });
      try {
        const raw = JSON.parse(body);
        if (!Array.isArray(raw) || raw.length > 64) return json(400, { error: 'expected an array of <=64 authorizations' });
        const isAddr = (x: unknown) => typeof x === 'string' && /^0x[0-9a-fA-F]{40}$/.test(x);
        const isHex = (x: unknown, n: number) => typeof x === 'string' && new RegExp(`^0x[0-9a-fA-F]{${n}}$`).test(x);
        const clean: Auth[] = [];
        for (const a of raw) {
          if (!(isAddr(a.token) && isAddr(a.payee) && isAddr(a.from) && isHex(a.r, 64) && isHex(a.s, 64)
            && Number.isInteger(a.installmentNo) && a.installmentNo >= 0 && a.installmentNo < 64
            && Number.isInteger(a.v) && Number.isInteger(a.validAfter) && Number.isInteger(a.validBefore)
            && /^[0-9]+$/.test(String(a.orderId)) && /^[0-9]+$/.test(String(a.amount)))) return json(400, { error: 'invalid authorization' });
          const key = `${a.orderId}:${a.installmentNo}:${a.from.toLowerCase()}`;
          if (state.autopay.some(x => `${x.orderId}:${x.installmentNo}:${x.from.toLowerCase()}` === key)) continue;   // dedup
          clean.push({ orderId: String(a.orderId), installmentNo: a.installmentNo, token: a.token, payee: a.payee,
            amount: String(a.amount), from: a.from, validAfter: a.validAfter, validBefore: a.validBefore, v: a.v, r: a.r, s: a.s });
        }
        if (state.autopay.length + clean.length > 1000) return json(429, { error: 'autopay queue full' });
        state.autopay.push(...clean); save(); json(200, { accepted: clean.length });
      } catch (e: any) { json(400, { error: e.message }); }
    });
    return;
  }
  if (req.method === 'GET' && (req.url === '/' || req.url === '/index.html')) {
    res.writeHead(200, { 'content-type': 'text/html', 'x-content-type-options': 'nosniff',
      'content-security-policy': "default-src 'none'; script-src 'unsafe-inline' https://cdnjs.cloudflare.com; connect-src 'self' " + env('SOURCE_CHAIN_RPC_URL') + ' ' + env('CREDITCOIN_RPC_URL') + "; img-src https://api.qrserver.com; style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com" });
    return res.end(readFileSync('web/index.html'));
  }
  res.writeHead(404); res.end();
}).listen(PORT, () => console.log(`checkout UI + API on http://localhost:${PORT}`));

(async function loop() {
  for (;;) {
    try { await autopay(); await collect(); await settleLoop(); }
    catch (e: any) { console.error(e.shortMessage ?? e.message); }
    await new Promise(r => setTimeout(r, POLL_MS));
  }
})();
