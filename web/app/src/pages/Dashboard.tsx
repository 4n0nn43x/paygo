import { useCallback, useEffect, useState } from 'react';
import { getAddress } from 'ethers';
import { useConfig } from '../lib/config';
import { useOrder } from '../hooks/useOrder';
import { Dock, type PanelKey } from '../components/dashboard/Dock';
import { BrandMark } from '../components/dashboard/BrandMark';
import { OrderCard } from '../components/dashboard/OrderCard';
import { SellerCard } from '../components/dashboard/SellerCard';
import { BuyerCard } from '../components/dashboard/BuyerCard';
import { CustodyCard } from '../components/dashboard/CustodyCard';
import { PassportCard } from '../components/dashboard/PassportCard';
import { ActivityFeed, type LogEntry } from '../components/dashboard/ActivityFeed';
import '../styles/dashboard.css';

const PANEL_TITLE: Record<PanelKey, string> = { seller: 'Sell on terms', buyer: 'Buy in installments', custody: 'Proof-of-Custody' };

// Deep link: #order=2&panel=buyer, so a demo order can be shared and reopened where it was.
function readHash() {
  const q = new URLSearchParams(location.hash.slice(1));
  const panel = q.get('panel') as PanelKey | null;
  return { order: q.get('order') || '1', panel: panel && panel in PANEL_TITLE ? panel : 'seller' as PanelKey };
}

export function Dashboard() {
  const { cfg, ccRead, sepRead, workerState } = useConfig();
  const [me, setMe] = useState<string | null>(null);
  const [{ order: orderId, panel }, setNav] = useState(readHash);
  const [localLog, setLocalLog] = useState<LogEntry[]>([]);
  const setOrderId = (order: string) => setNav(n => ({ ...n, order }));
  const setPanel = (panel: PanelKey) => setNav(n => ({ ...n, panel }));

  useEffect(() => { history.replaceState(null, '', `#order=${encodeURIComponent(orderId)}&panel=${panel}`); }, [orderId, panel]);

  const log = useCallback((msg: string, cls = '') => {
    setLocalLog(prev => [{ t: new Date().toLocaleTimeString(), msg, cls }, ...prev]);
  }, []);

  async function connect() {
    const eth = (window as any).ethereum;
    if (!eth) { log('no wallet found: install MetaMask', 'bad'); return; }
    const [a] = await eth.request({ method: 'eth_requestAccounts' });
    const addr = getAddress(a);
    setMe(addr);
    log('connected ' + addr);
  }

  if (!cfg || !ccRead || !sepRead) return <div className="boot">Connecting…</div>;
  return <Ready cfg={cfg} ccRead={ccRead} sepRead={sepRead} me={me} connect={connect} orderId={orderId} setOrderId={setOrderId}
    panel={panel} setPanel={setPanel} log={log} localLog={localLog} workerState={workerState} />;
}

function Ready({ cfg, ccRead, sepRead, me, connect, orderId, setOrderId, panel, setPanel, log, localLog, workerState }: any) {
  const { state, reload } = useOrder(cfg, ccRead, orderId);
  const order = state.kind === 'ok' ? state.order : null;
  return (
    <>
      <header>
        <div className="nav">
          <a className="brand" href="/"><BrandMark className="mark" />PayGo</a>
          <span className="tagline">Escrow on Creditcoin, paid on Ethereum, proven by Attestcoin.</span>
          {me ? <span id="who" className="mono" title={me}><i className="dot" />{me.slice(0, 6)}…{me.slice(-4)}</span>
            : <button id="connect" onClick={connect}>Connect wallet</button>}
        </div>
      </header>
      <main className="app">
        <Dock active={panel} onSelect={setPanel} />
        <div className="content">
          <OrderCard cfg={cfg} state={state} orderId={orderId} setOrderId={setOrderId} reload={reload} log={log} />
          <div className="grid">
            <div className="col">
              <section className="card">
                <h2>{PANEL_TITLE[panel as PanelKey]}</h2>
                {panel === 'seller' && <SellerCard cfg={cfg} sepRead={sepRead} me={me} log={log} onOrderCreated={(id: string) => { setOrderId(id); setPanel('buyer'); }} />}
                {panel === 'buyer' && <BuyerCard cfg={cfg} me={me} log={log} order={order} reload={reload} />}
                {panel === 'custody' && <CustodyCard cfg={cfg} ccRead={ccRead} log={log} orderId={orderId} reload={reload} />}
              </section>
            </div>
            <div className="col">
              <PassportCard cfg={cfg} ccRead={ccRead} me={me} />
              <ActivityFeed state={workerState} localLog={localLog} />
            </div>
          </div>
        </div>
      </main>
    </>
  );
}
