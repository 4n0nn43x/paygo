import { useState } from 'react';
import { ArrowRight, ImageOff, RefreshCw } from 'lucide-react';
import { STATUS } from '../../lib/abis';
import { fmt } from '../../lib/format';
import type { MyOrdersState } from '../../hooks/useMyOrders';

const LABEL: Record<string, string> = { Active: 'Active', DefaultAsserted: 'Default asserted', Defaulted: 'Defaulted', Completed: 'Completed' };
const CLS = ['ok', 'warn', 'bad', 'ok'] as const;

/** The landing card: the orders you are actually a party to. Inspecting an arbitrary id is still
 *  possible, since every order is public, but it lives at the bottom, where a stranger's
 *  transaction belongs, instead of being what the page opens on. */
export function MyOrders({ state, me, connect, onOpen, reload }: {
  state: MyOrdersState; me: string | null; connect: () => void;
  onOpen: (id: string) => void; reload: () => void;
}) {
  const [lookup, setLookup] = useState('');
  const rows = state.kind === 'ok' ? state.rows : [];

  return (
    <section className="card order">
      <div className="page-h">
        <h1>Your orders</h1>
        {state.kind === 'ok' && me && <span className="pill">{rows.length || 'none'}</span>}
        {state.kind === 'loading' && <span className="pill">loading</span>}
        {state.kind === 'error' && <span className="pill bad">{state.message}</span>}
        {me && <button className="icon-btn" onClick={reload} aria-label="Refresh" title="Refresh"><RefreshCw aria-hidden="true" /></button>}
        {!me && <div className="page-actions"><button onClick={connect}>Connect wallet</button></div>}
      </div>

      {!me ? (
        <div className="empty-t">Connect a wallet to see the orders you are buying or selling. Nothing here is yours until you do.</div>
      ) : state.kind === 'loading' ? (
        <div className="empty-t">Reading them from Creditcoin…</div>
      ) : rows.length === 0 ? (
        <div className="empty-t">No order names this wallet yet. Put something up for sale with the <b>Sell</b> panel, and it opens here.</div>
      ) : (
        <div className="order-list">
          {rows.map(r => (
            <button key={r.id} type="button" className="order-row" onClick={() => onOpen(r.id)}>
              <span className="thumb sm">
                {r.image ? <img src={r.image} alt="" onError={e => { (e.target as HTMLImageElement).style.display = 'none'; }} />
                  : <ImageOff strokeWidth={1.25} aria-hidden="true" />}
              </span>
              <span className="order-row-main">
                <span className="order-row-top">
                  <b>{r.name}</b>
                  <span className={`pill ${CLS[r.status]}`}>{LABEL[STATUS[r.status]]}</span>
                </span>
                <span className="mut">#{r.id} · you are the {r.role} · {r.paidCount} of {r.n} proven · {fmt(r.price)}</span>
              </span>
              <ArrowRight aria-hidden="true" />
            </button>
          ))}
        </div>
      )}

      <form className="lookup" onSubmit={e => { e.preventDefault(); const v = lookup.trim(); if (v) onOpen(v); }}>
        <label htmlFor="lookup">Open any order by number <span className="mut">(every order on PayGo is public)</span></label>
        <div className="row-add">
          <input id="lookup" className="mono" value={lookup} inputMode="numeric" placeholder="e.g. 1"
            onChange={e => setLookup(e.target.value)} />
          <button type="submit" className="sec">Open</button>
        </div>
      </form>
    </section>
  );
}
