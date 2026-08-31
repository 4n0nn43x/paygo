import { useState } from 'react';
import { Contract } from 'ethers';
import type { JsonRpcProvider } from 'ethers';
import { ESCROW_ABI, CHAININFO_ABI, CHAININFO_ADDRESS, STATUS } from '../../lib/abis';
import { net, CC, errMsg } from '../../lib/chain';

export function TrackerCard({ cfg, ccRead, log, orderId, setOrderId }: {
  cfg: { escrow: string; chainKey: number }; ccRead: JsonRpcProvider; log: (m: string, c?: string) => void;
  orderId: string; setOrderId: (id: string) => void;
}) {
  const [out, setOut] = useState<React.ReactNode>(null);

  async function track() {
    const esc = new Contract(cfg.escrow, ESCROW_ABI, ccRead);
    const id = +orderId;
    const o = await esc.getOrder(id);
    if (o.n == 0) { setOut('no such order'); return; }
    const ci = new Contract(CHAININFO_ADDRESS, CHAININFO_ABI, ccRead);
    const att = await ci.get_latest_attestation_height_and_hash(cfg.chainKey);
    const grace = await esc.GRACE();
    const cure = await esc.CURE_WINDOW();
    const ccBlock = await ccRead.getBlockNumber();
    let k = 0;
    for (; k < o.n; k++) if (!(await esc.paid(id, k))) break;
    const dl = k < o.n ? o.firstDeadline + BigInt(k) * o.interval : null;
    const cls = (['ok', 'warn', 'bad', 'ok'] as const)[o.status];
    const rows: React.ReactNode[] = [
      <p key="s">status <span className={`pill ${cls}`}>{STATUS[o.status]}</span> · paid {o.paidCount}/{o.n} · asset #{String(o.tokenId)}</p>,
      <p key="a" className="mut">attested Sepolia height <b>{String(att.height)}</b>
        {dl != null && <> · next deadline {String(dl)} (+grace {String(grace)} = {String(dl + grace)}) → {att.height > dl + grace ? <span className="bad">overdue: default can be asserted</span> : <span className="ok">in time</span>}</>}
      </p>,
    ];
    if (o.status == 1) rows.push(<p key="d" className="warn">default asserted on installment #{o.disputedNo} at CC3 block {String(o.assertedAt)}; cure window ends at {String(o.assertedAt + cure)} (now {ccBlock}). A proof of an on-time payment cures it.</p>);
    if (o.status == 3) rows.push(<p key="c" className="ok">asset transferred to buyer {o.buyer}</p>);
    if (o.status == 2) rows.push(<p key="f" className="bad">asset returned to seller {o.seller}; paid installments kept.</p>);
    setOut(rows);
  }

  async function declareDefault() {
    try {
      const s = await net(CC.chainId, CC);
      const tx = await new Contract(cfg.escrow, ESCROW_ABI, s).declareDefault(+orderId);
      await tx.wait();
      log('default asserted ' + tx.hash, 'warn');
      track();
    } catch (e) { log(errMsg(e), 'bad'); }
  }

  async function finalizeDefault() {
    try {
      const s = await net(CC.chainId, CC);
      const tx = await new Contract(cfg.escrow, ESCROW_ABI, s).finalizeDefault(+orderId);
      await tx.wait();
      log('default finalized ' + tx.hash, 'bad');
      track();
    } catch (e) { log(errMsg(e), 'bad'); }
  }

  return (
    <section className="card"><h2><span className="n">3</span> Tracker</h2>
      <div className="desc">Live from Creditcoin: the order only moves when a proof lands. Silence after grace = default; a proof of an on-time payment cures it.</div>
      <label>Order id</label><input id="t-id" value={orderId} onChange={e => setOrderId(e.target.value)} /><button id="t-load" className="sec" onClick={track}>Refresh</button>
      <div id="t-out">{out}</div>
      <button id="t-default" className="sec" onClick={declareDefault}>Declare default (anyone)</button> <button id="t-final" className="sec" onClick={finalizeDefault}>Finalize default</button>
    </section>
  );
}
