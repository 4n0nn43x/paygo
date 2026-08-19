// Measures the raw precompile cost of a proof as it ages: fresh vs ~24h vs ~7d old Sepolia txs.
// eth_estimateGas against BlockProver.verify (view) on CC3 — no contract needed.
//   node script/gas-probe.mjs            (uses .env for RPCs / prover)
import 'dotenv/config';
import { Contract, JsonRpcProvider } from 'ethers';
import { proofProvider } from '@gluwa/usc-sdk';

const sep = new JsonRpcProvider(process.env.SOURCE_CHAIN_RPC_URL);
const cc = new JsonRpcProvider(process.env.CREDITCOIN_RPC_URL);
const prover = new proofProvider.service.ProofBuilder(1, process.env.PROOF_BUILDER_URL);
const verifier = new Contract('0x0000000000000000000000000000000000000FD2', [
  'function verify(uint64 chainKey,uint64 height,bytes encodedTransaction,(bytes32 root,(bytes32 hash,bool isLeft)[] siblings) merkleProof,(bytes32 lowerEndpointDigest,bytes32[] roots) continuityProof) view returns (bool)',
], cc);

const attested = (await (await fetch(`${process.env.PROOF_BUILDER_URL}/api/v1/attested-height/1`)).json()).attestedHeight;
const BLOCKS_PER_HOUR = 300; // Sepolia ~12s
const ages = [{ label: 'fresh (~10 min)', back: 50 }, { label: '+6 h', back: 6 * BLOCKS_PER_HOUR }, { label: '+24 h', back: 24 * BLOCKS_PER_HOUR }, { label: '+7 d', back: 7 * 24 * BLOCKS_PER_HOUR }];

async function firstTxWithLogs(height) {
  for (let h = height; h > height - 20; h--) {
    const b = await sep.getBlock(h);
    for (const hash of b.transactions.slice(0, 10)) {
      const r = await sep.getTransactionReceipt(hash);
      if (r && r.status === 1 && r.logs.length === 1 && (await sep.getTransaction(hash)).data.length < 300) return hash;
    }
  }
  throw new Error('no small tx found near ' + height);
}

console.log(`attested height ${attested}\n`);
console.log('| age | height | continuity roots | verify() gas |');
console.log('|---|---|---|---|');
for (const a of ages) {
  const height = attested - a.back;
  const hash = await firstTxWithLogs(height);
  const p = await prover.getProof(hash);
  if (!p.success) { console.log(`| ${a.label} | ${height} | — | proof failed: ${p.error} |`); continue; }
  const d = p.data;
  const gas = await verifier.verify.estimateGas(d.chainKey, d.headerNumber, d.txBytes, d.merkleProof, d.continuityProof);
  console.log(`| ${a.label} | ${d.headerNumber} | ${d.continuityProof.roots.length} | ${gas} |`);
}
