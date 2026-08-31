import { useState } from 'react';
import { Contract, Signature, AbiCoder, keccak256 } from 'ethers';
import type { JsonRpcProvider } from 'ethers';
import { ESCROW_ABI, ROUTER_ABI, USDC_ABI } from '../../lib/abis';
import { net, SEP, errMsg } from '../../lib/chain';
import { fmt } from '../../lib/format';
import type { Cfg } from '../../lib/config';
import { ScheduleTimeline, type ScheduleStep } from './ScheduleTimeline';
import { AssetPreview } from './AssetPreview';
import { fetchAssetMeta, type AssetMeta } from '../../lib/assetMeta';

type Order = {
  n: bigint; amounts: bigint[]; firstDeadline: bigint; interval: bigint; payee: string; asset: string; tokenId: bigint;
};

export function BuyerCard({ cfg, ccRead, me, log, orderId, setOrderId }: {
  cfg: Cfg; ccRead: JsonRpcProvider; me: string | null; log: (m: string, c?: string) => void;
  orderId: string; setOrderId: (id: string) => void;
}) {
  const [gap, setGap] = useState('90');
  const [sched, setSched] = useState<React.ReactNode>(null);
  const [steps, setSteps] = useState<ScheduleStep[]>([]);
  const [assetMeta, setAssetMeta] = useState<AssetMeta | null>(null);
  const [out, setOut] = useState<React.ReactNode>(null);

  async function loadOrder(): Promise<Order | null> {
    const esc = new Contract(cfg.escrow, ESCROW_ABI, ccRead);
    const id = +orderId;
    const o = await esc.getOrder(id);
    if (o.n == 0) { setSched('no such order'); setSteps([]); setAssetMeta(null); return null; }
    setAssetMeta(await fetchAssetMeta(o.asset, o.tokenId, ccRead));
    const rows: React.ReactNode[] = [];
    const newSteps: ScheduleStep[] = [];
    for (let i = 0; i < o.n; i++) {
      const p = await esc.paid(id, i);
      const deadline = o.firstDeadline + BigInt(i) * o.interval;
      rows.push(
        <tr key={i}><td>{i}</td><td>{fmt(o.amounts[i])}</td><td>{String(deadline)}</td>
          <td>{p ? <span className="ok">proven ✓</span> : <span className="mut">due</span>}</td></tr>
      );
      newSteps.push({ no: i, amount: o.amounts[i], deadline, paid: p });
    }
    setSched(<table><tbody><tr><th>#</th><th>amount</th><th>deadline (Sepolia height)</th><th></th></tr>{rows}</tbody></table>);
    setSteps(newSteps);
    return o;
  }

  async function permitDigest(usdc: Contract, owner: string, spender: string, value: bigint, deadline: number) {
    const nonce = await usdc.nonces(owner);
    const name = await usdc.name();
    return {
      domain: { name, version: '1', chainId: 11155111, verifyingContract: cfg.usdc },
      types: { Permit: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'nonce', type: 'uint256' }, { name: 'deadline', type: 'uint256' }] },
      msg: { owner, spender, value, nonce, deadline },
    };
  }

  async function payDeposit() {
    try {
      const o = await loadOrder();
      if (!o) return;
      const s = await net(SEP.chainId, SEP);
      const usdc = new Contract(cfg.usdc, USDC_ABI, s);
      const router = new Contract(cfg.router, ROUTER_ABI, s);
      const id = +orderId;
      const amt = o.amounts[0];
      if ((await usdc.balanceOf(me)) < amt) { setOut('minting test USDC…'); await (await usdc.mint(me, amt * 4n)).wait(); }
      const dl = Math.floor(Date.now() / 1000) + 3600;
      const d = await permitDigest(usdc, me!, cfg.router, amt, dl);
      const sig = Signature.from(await s.signTypedData(d.domain, d.types, d.msg));
      const tx = await router.payWithPermit(cfg.escrow, id, 0, cfg.usdc, o.payee, amt, dl, sig.v, sig.r, sig.s);
      setOut('paying… ' + tx.hash);
      await tx.wait();
      setOut(<>deposit paid on Sepolia: <span className="ok">{tx.hash}</span><br />the worker will prove it on Creditcoin in ~10 min</>);
      log('deposit paid ' + tx.hash, 'ok');
    } catch (e) { setOut(errMsg(e)); }
  }

  async function autopay() {
    try {
      const o = await loadOrder();
      if (!o) return;
      const s = await net(SEP.chainId, SEP);
      const usdc = new Contract(cfg.usdc, USDC_ABI, s);
      const id = +orderId;
      const g = +gap;
      const now = Math.floor(Date.now() / 1000);
      let total = 0n;
      for (let i = 1; i < o.n; i++) total += o.amounts[i];
      if ((await usdc.balanceOf(me)) < total) { setOut('minting test USDC…'); await (await usdc.mint(me, total)).wait(); }
      const domain = { name: await usdc.name(), version: '1', chainId: 11155111, verifyingContract: cfg.usdc };
      const types = { ReceiveWithAuthorization: [{ name: 'from', type: 'address' }, { name: 'to', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'validAfter', type: 'uint256' }, { name: 'validBefore', type: 'uint256' }, { name: 'nonce', type: 'bytes32' }] };
      const abi = AbiCoder.defaultAbiCoder();
      const list: any[] = [];
      for (let i = 1; i < o.n; i++) {
        const validAfter = now + g * i, validBefore = validAfter + 7 * 86400;
        const value = o.amounts[i];
        // routing-bound nonce = keccak256(escrow, orderId, installmentNo, payee): the Router recomputes it, so payee can't be swapped
        const nonce = keccak256(abi.encode(['address', 'uint256', 'uint8', 'address'], [cfg.escrow, id, i, o.payee]));
        const sig = Signature.from(await s.signTypedData(domain, types, { from: me, to: cfg.router, value, validAfter, validBefore, nonce }));
        list.push({ orderId: String(id), installmentNo: i, token: cfg.usdc, payee: o.payee, amount: value.toString(), from: me, validAfter, validBefore, v: sig.v, r: sig.r, s: sig.s });
      }
      const r = await (await fetch('/authorizations', { method: 'POST', body: JSON.stringify(list) })).json();
      setOut(<><span className="ok">{r.accepted} authorizations signed &amp; handed to the worker.</span> Close your laptop — installments pay themselves every {gap}s and get proven on Creditcoin.</>);
      log('autopay armed: ' + r.accepted + ' installments', 'ok');
    } catch (e) { setOut(errMsg(e)); }
  }

  return (
    <section className="card"><h2><span className="n">2</span> Buyer — checkout</h2>
      <div className="desc">Ethereum Sepolia. Pay the deposit in one click (permit), then <b>sign once</b> for the rest: authorizations are submitted by anyone when due (EIP-3009).</div>
      <label>Order id</label><input id="b-id" value={orderId} onChange={e => setOrderId(e.target.value)} />
      <button id="b-load" className="sec" onClick={loadOrder}>Load order</button>
      <AssetPreview meta={assetMeta} />
      <ScheduleTimeline steps={steps} />
      <div id="b-sched">{sched}</div>
      <label>Autopay: seconds between installments (demo; production = aligned on deadlines)</label><input id="b-gap" value={gap} onChange={e => setGap(e.target.value)} />
      <button id="b-deposit" onClick={payDeposit}>Pay deposit now (permit, 1 tx)</button>
      <button id="b-autopay" onClick={autopay}>Sign once → autopay the rest</button>
      <div id="b-out" className="mono">{out}</div>
    </section>
  );
}
