import { Contract } from 'ethers';
import { RefreshCw, AlertTriangle, Gavel, PackageCheck, Undo2, ImageOff, Lock, ShieldCheck, ShieldAlert } from 'lucide-react';
import { ESCROW_ABI, STATUS } from '../../lib/abis';
import { net, CC, errMsg } from '../../lib/chain';
import { fmt } from '../../lib/format';
import type { OrderState } from '../../hooks/useOrder';
import { ScheduleTimeline } from './ScheduleTimeline';

const LABEL: Record<string, string> = { Active: 'Active', DefaultAsserted: 'Default asserted', Defaulted: 'Defaulted', Completed: 'Completed' };
const CLS = ['ok', 'warn', 'bad', 'ok'] as const;
const ZERO = '0x0000000000000000000000000000000000000000';
const short = (a: string) => a.slice(0, 6) + '…' + a.slice(-4);

/** The order, in one card: what is being bought, by whom, its verdict, the one action its state allows, and the four numbers. */
export function OrderCard({ cfg, state, orderId, setOrderId, reload, log }: {
  cfg: { escrow: string }; state: OrderState; orderId: string; setOrderId: (id: string) => void;
  reload: () => void; log: (m: string, c?: string) => void;
}) {
  const o = state.kind === 'ok' ? state.order : null;

  async function call(fn: 'declareDefault' | 'finalizeDefault' | 'claimAsset' | 'withdrawAsset', done: string, cls = 'ok') {
    try {
      const s = await net(CC.chainId, CC);
      const tx = await new Contract(cfg.escrow, ESCROW_ABI, s)[fn](+orderId);
      log(done + '… ' + tx.hash);
      await tx.wait();
      log(done + ' ' + tx.hash, cls);
      reload();
    } catch (e) { log(errMsg(e), 'bad'); }
  }

  const action = !o ? null
    : o.status === 0 && o.overdue ? <button onClick={() => call('declareDefault', 'default asserted', 'warn')}><AlertTriangle aria-hidden="true" />Declare default <span className="hint">anyone can</span></button>
    : o.status === 1 && o.cureEndsAt != null && BigInt(o.ccBlock) > o.cureEndsAt ? <button onClick={() => call('finalizeDefault', 'default finalized', 'bad')}><Gavel aria-hidden="true" />Finalize default</button>
    : o.status === 3 ? <button onClick={() => call('claimAsset', 'asset claimed')}><PackageCheck aria-hidden="true" />Claim the asset <span className="hint">buyer</span></button>
    : o.status === 2 ? <button onClick={() => call('withdrawAsset', 'asset withdrawn')}><Undo2 aria-hidden="true" />Take the asset back <span className="hint">seller</span></button>
    : null;

  const next = o?.nextDeadline != null && o.nextNo != null ? o.nextDeadline : null;
  const name = o ? (o.meta?.name || `Demo asset #${o.tokenId}`) : '';

  return (
    <section className="card order">
      <div className="page-h">
        <h1>Order <input className="order-input mono" value={orderId} onChange={e => setOrderId(e.target.value)} aria-label="Order id" /></h1>
        {o && <span className={`pill ${CLS[o.status]}`}>{LABEL[STATUS[o.status]]}</span>}
        {state.kind === 'loading' && <span className="pill">loading</span>}
        {state.kind === 'error' && <span className="pill bad">{state.message}</span>}
        <button className="icon-btn" onClick={reload} aria-label="Refresh" title="Refresh"><RefreshCw aria-hidden="true" /></button>
        <div className="page-actions">{action}</div>
      </div>

      {!o ? (
        <div className="empty-t">
          {state.kind === 'missing' ? `No order #${orderId} yet. Type another id, or list an asset with the Sell panel: the order it creates opens here.`
            : state.kind === 'loading' ? 'Reading the order from Creditcoin…' : 'Type an order id, or list an asset with the Sell panel.'}
        </div>
      ) : (
        <div className="order-body">
          <div className="order-who">
            <div className="thumb">
              {o.meta?.image ? <img src={o.meta.image} alt={name} onError={e => { (e.target as HTMLImageElement).style.display = 'none'; }} /> : <ImageOff strokeWidth={1.25} aria-hidden="true" />}
            </div>
            <div className="order-meta">
              <div className="asset-coll">Demo asset · #{String(o.tokenId)}</div>
              <h2>{name}</h2>
              {o.meta?.description && <p className="desc">{o.meta.description}</p>}
              <div className="parties">
                <div><span className="k">Seller</span><span className="mono">{short(o.seller)}</span></div>
                <div><span className="k">Buyer</span><span className="mono">{short(o.buyer)}</span></div>
                <div><span className="k">Asset</span><span className="mut"><Lock aria-hidden="true" />{o.status === 3 ? 'released to buyer' : o.status === 2 ? 'back to seller' : 'escrowed'}</span></div>
                <div><span className="k">Authenticity</span>
                  {o.custodyVerified ? <span className="ok"><ShieldCheck aria-hidden="true" />chip matched</span>
                    : o.custodyDisputed ? <span className="bad"><ShieldAlert aria-hidden="true" />substitution proven</span>
                    : o.chipId !== ZERO ? <span className="mut">chip bound</span> : <span className="mut">no chip yet</span>}
                </div>
              </div>
            </div>
          </div>
          <div className="kpis">
            <div className="kpi hot">
              <div className="k">Paid so far</div>
              <div className="v">{o.paidCount} / {o.n}</div>
              <div className="s">{fmt(o.paidAmount)} of {fmt(o.price)}</div>
            </div>
            <div className="kpi">
              <div className="k">Next installment</div>
              <div className="v">{o.nextNo != null ? fmt(o.amounts[o.nextNo]) : 'none'}</div>
              <div className="s">{next != null ? `due by Ethereum block ${next}` : 'schedule complete'}</div>
            </div>
            <div className="kpi">
              <div className="k">Time left</div>
              <div className="v">{next != null ? (o.overdue ? <span className="bad">overdue</span> : o.att > next ? <span className="warn">in grace</span> : <span className="ok">in time</span>) : '–'}</div>
              <div className="s">{next != null ? `grace ends at block ${next + o.grace}` : 'nothing due'}</div>
            </div>
            <div className="kpi">
              <div className="k">{o.status === 1 ? 'Cure window' : 'Attested clock'}</div>
              <div className="v">{o.status === 1 && o.cureEndsAt != null ? `${o.cureEndsAt - BigInt(o.ccBlock)} blocks` : String(o.att)}</div>
              <div className="s">{o.status === 1 ? 'a proof of an on-time payment still cures it' : 'latest Ethereum height proven on Creditcoin'}</div>
            </div>
          </div>
          <div className="order-sched">
            <div className="sched-h"><h2>Schedule</h2><span className="mut">{o.paidCount} of {o.n} proven</span></div>
            <ScheduleTimeline steps={o.steps} />
            <table className="sched-table"><tbody>
              {o.steps.map(s => (
                <tr key={s.no} className={s.no === o.nextNo ? 'next' : ''}>
                  <td className="mono">#{s.no}</td>
                  <td>{s.no === 0 ? 'deposit' : `installment ${s.no}`}</td>
                  <td className="mono">block {String(s.deadline)}</td>
                  <td className="mono num">{fmt(s.amount)}</td>
                  <td>{s.paid ? <span className="pill ok">proven</span> : s.no === o.nextNo ? <span className="pill warn">next</span> : <span className="pill">due</span>}</td>
                </tr>
              ))}
            </tbody></table>
          </div>
        </div>
      )}
    </section>
  );
}
