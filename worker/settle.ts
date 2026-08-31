// PayGo worker — a convenience relayer, nothing more: `settle`/`settleCustody` are permissionless,
// anyone (the buyer included) can submit the same proofs by hand. It does four things:
//   1. autopay: submits the EIP-3009 authorizations the buyer pre-signed at checkout, when they become valid
//   2. settle:  listen InstallmentPaid on Sepolia → wait until attested → one batch proof per ≤10 txs /
//               ≤1000-block window → PayGoEscrow.settle on Creditcoin
//   3. settleCustody: same shape, for CustodyRouter's PossessionAttested (Proof-of-Custody chip scans)
//   4. serves the built web/dist (Vite: web/app -> landing at /, dashboard at /dashboard/) + a tiny
//      JSON API (POST /authorizations, GET /state) for the checkout
import 'dotenv/config';
import { Contract, JsonRpcProvider, Wallet } from 'ethers';
import { proofProvider } from '@gluwa/usc-sdk';
import { readFileSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join, resolve } from 'node:path';

const env = (k: string) => { const v = process.env[k]; if (!v) throw new Error(`missing env ${k}`); return v; };
const CHAIN_KEY = Number(env('SOURCE_CHAIN_KEY'));
const MAX_BATCH = 10, MAX_RANGE = 1000, POLL_MS = 15_000;
const STATE_FILE = process.env.WORKER_STATE ?? 'worker/state.json';
const PORT = Number(process.env.PORT ?? 8787);

const ROUTER_ABI = [
  'event InstallmentPaid(address indexed escrow,uint256 indexed orderId,uint8 installmentNo,address payer,address payee,address token,uint256 amount)',
  'function payWithAuthorization(address escrow,uint256 orderId,uint8 installmentNo,address token,address payee,uint256 amount,(address from,uint256 validAfter,uint256 validBefore,uint8 v,bytes32 r,bytes32 s) a)',
];
const CUSTODY_ROUTER_ABI = ['event PossessionAttested(address indexed escrow,uint256 indexed orderId,address chip,uint8 role,address submitter)'];
const ESCROW_ABI = [
  'function settle(uint64[] heights,bytes[] txs,(bytes32 root,(bytes32 hash,bool isLeft)[] siblings)[] proofs,(bytes32 lowerEndpointDigest,bytes32[] roots) continuity)',
  'function settleCustody(uint64[] heights,bytes[] txs,(bytes32 root,(bytes32 hash,bool isLeft)[] siblings)[] proofs,(bytes32 lowerEndpointDigest,bytes32[] roots) continuity)',
];

const sepolia = new JsonRpcProvider(env('SOURCE_CHAIN_RPC_URL'));
const cc = new JsonRpcProvider(env('CREDITCOIN_RPC_URL'));
const ccWallet = new Wallet(env('CREDITCOIN_WALLET_PRIVATE_KEY'), cc);
const sepWallet = new Wallet(env('CREDITCOIN_WALLET_PRIVATE_KEY'), sepolia);
const router = new Contract(env('ROUTER_ADDRESS'), ROUTER_ABI, sepWallet);
const custodyRouter = process.env.CUSTODY_ROUTER_ADDRESS ? new Contract(process.env.CUSTODY_ROUTER_ADDRESS, CUSTODY_ROUTER_ABI, sepWallet) : undefined;
const escrow = new Contract(env('ESCROW_ADDRESS'), ESCROW_ABI, ccWallet);
const prover = new proofProvider.service.ProofBuilder(CHAIN_KEY, env('PROOF_BUILDER_URL'));

type Pending = { hash: string; height: number };
type Auth = { orderId: string; installmentNo: number; token: string; payee: string; amount: string;
  from: string; validAfter: number; validBefore: number; v: number; r: string; s: string; txHash?: string; error?: string };
const state: {
  fromBlock: number; pending: Pending[]; done: string[]; autopay: Auth[]; settles: { tx: string; count: number; gas: string }[];
  custodyFromBlock: number; custodyPending: Pending[]; custodyDone: string[];
} = existsSync(STATE_FILE)
  ? { autopay: [], settles: [], custodyFromBlock: 0, custodyPending: [], custodyDone: [], ...JSON.parse(readFileSync(STATE_FILE, 'utf8')) }
  : { fromBlock: Number(process.env.START_BLOCK ?? 0), pending: [], done: [], autopay: [], settles: [],
      custodyFromBlock: Number(process.env.START_BLOCK ?? 0), custodyPending: [], custodyDone: [] };
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

// ---- 3. settleCustody (same shape as 2, for CustodyRouter's PossessionAttested)
async function collectCustody() {
  if (!custodyRouter) return;
  const head = await sepolia.getBlockNumber();
  if (state.custodyFromBlock === 0) state.custodyFromBlock = head;
  if (head < state.custodyFromBlock) return;
  const to = Math.min(head, state.custodyFromBlock + 5000);
  const logs = await custodyRouter.queryFilter('PossessionAttested', state.custodyFromBlock, to);
  for (const l of logs) {
    if (!state.custodyDone.includes(l.transactionHash) && !state.custodyPending.some(p => p.hash === l.transactionHash)) {
      state.custodyPending.push({ hash: l.transactionHash, height: l.blockNumber });
      console.log(`+ custody attestation ${l.transactionHash} @${l.blockNumber}`);
    }
  }
  state.custodyFromBlock = to + 1;
  save();
}

async function settleCustodyBatch(batch: Pending[]) {
  const top = Math.max(...batch.map(p => p.height));
  console.log(`waiting attestation of custody height ${top} (${batch.length} tx)…`);
  await prover.waitUntilHeightAttested(CHAIN_KEY, top, POLL_MS, 30 * 60_000);
  const res = await prover.getBatchProof(batch.map(p => p.hash));
  if (!res.success || !res.data) throw new Error(res.error);
  const heights: number[] = [], txs: string[] = [], proofs: any[] = [];
  for (const [h, m] of res.data.merkleProofs) for (const [, e] of m) { heights.push(h); txs.push(e.txBytes); proofs.push(e.merkleProof); }
  const args = [heights, txs, proofs, res.data.continuityProof];
  await escrow.settleCustody.staticCall(...args);
  const tx = await escrow.settleCustody(...args, { gasLimit: 2_000_000 });
  console.log(`settleCustody ${heights.length} tx → ${tx.hash}`);
  await tx.wait();
  state.custodyDone.push(...batch.map(p => p.hash));
  state.custodyPending = state.custodyPending.filter(p => !batch.includes(p));
  save();
}

async function custodySettleLoop() {
  if (!state.custodyPending.length) return;
  const sorted = [...state.custodyPending].sort((a, b) => a.height - b.height);
  const lo = sorted[0].height;
  const batch = sorted.filter(p => p.height - lo < MAX_RANGE).slice(0, MAX_BATCH);
  const head = await sepolia.getBlockNumber();
  if (!(batch.length === MAX_BATCH || head - lo >= MAX_RANGE || process.env.SETTLE_NOW)) return;
  try { await settleCustodyBatch(batch); }
  catch (e: any) {
    console.error('custody batch failed:', e.shortMessage ?? e.message);
    if (batch.length > 1) for (const p of batch) { try { await settleCustodyBatch([p]); } catch (e2: any) { console.error(`  ${p.hash}: ${e2.shortMessage ?? e2.message}`); } }
  }
}

// ---- 4. checkout UI (Vite build in web/dist) + API
const WEB_DIST = resolve('web/dist');
const MIME: Record<string, string> = {
  '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon',
  '.woff': 'font/woff', '.woff2': 'font/woff2', '.json': 'application/json',
};
function mimeType(file: string) { return MIME[extname(file)] ?? 'application/octet-stream'; }

/** Resolves a request path to a file under web/dist, or null. Multi-page: / -> index.html,
 *  /dashboard or /dashboard/ -> dashboard/index.html, everything else must be a real asset file. */
function staticFilePath(url: string): string | null {
  const path = url.split('?')[0];
  if (path === '/') return join(WEB_DIST, 'index.html');
  if (path === '/dashboard' || path === '/dashboard/') return join(WEB_DIST, 'dashboard', 'index.html');
  const candidate = resolve(join(WEB_DIST, path));
  if (!candidate.startsWith(WEB_DIST + '/')) return null; // path traversal guard
  try { return statSync(candidate).isFile() ? candidate : null; } catch { return null; }
}
createServer((req, res) => {
  const json = (code: number, body: unknown) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
  if (req.method === 'GET' && req.url === '/state') return json(200, {
    router: env('ROUTER_ADDRESS'), custodyRouter: process.env.CUSTODY_ROUTER_ADDRESS, escrow: env('ESCROW_ADDRESS'),
    usdc: process.env.USDC_ADDRESS, asset: process.env.ASSET_ADDRESS,
    chainKey: CHAIN_KEY, sepoliaRpc: env('SOURCE_CHAIN_RPC_URL'), ccRpc: env('CREDITCOIN_RPC_URL'),
    pending: state.pending, autopay: state.autopay, settles: state.settles, done: state.done.length,
    custodyPending: state.custodyPending, custodyDone: state.custodyDone.length,
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
  if (req.method === 'GET') {
    // Vite build (web/app -> web/dist): landing at /, dashboard at /dashboard/, hashed assets in
    // between. No inline script/style anymore (ethers is bundled, not CDN-loaded), so CSP drops
    // 'unsafe-inline' entirely — a tightening, not a relaxation, of the pre-migration policy.
    const csp = "default-src 'none'; script-src 'self'; connect-src 'self' " + env('SOURCE_CHAIN_RPC_URL') + ' ' + env('CREDITCOIN_RPC_URL') + "; img-src 'self' https://api.qrserver.com; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com";
    const file = staticFilePath(req.url ?? '/');
    if (file) {
      res.writeHead(200, { 'content-type': mimeType(file), 'x-content-type-options': 'nosniff', 'content-security-policy': csp });
      return res.end(readFileSync(file));
    }
  }
  res.writeHead(404); res.end();
}).listen(PORT, () => console.log(`checkout UI + API on http://localhost:${PORT}`));

(async function loop() {
  for (;;) {
    try { await autopay(); await collect(); await settleLoop(); await collectCustody(); await custodySettleLoop(); }
    catch (e: any) { console.error(e.shortMessage ?? e.message); }
    await new Promise(r => setTimeout(r, POLL_MS));
  }
})();
