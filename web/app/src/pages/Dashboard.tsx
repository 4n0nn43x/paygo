import { useCallback, useEffect, useState } from 'react';
import { getAddress } from 'ethers';
import { useConfig, type WorkerState } from '../lib/config';
import { BrandMark } from '../components/dashboard/BrandMark';
import { SellerCard } from '../components/dashboard/SellerCard';
import { BuyerCard } from '../components/dashboard/BuyerCard';
import { TrackerCard } from '../components/dashboard/TrackerCard';
import { PassportCard } from '../components/dashboard/PassportCard';
import { CustodyCard } from '../components/dashboard/CustodyCard';
import { WorkerLog, type LogEntry } from '../components/dashboard/WorkerLog';
import { Sidebar, type PanelKey } from '../components/dashboard/Sidebar';
import { GasChart } from '../components/dashboard/GasChart';
import '../styles/dashboard.css';

export function Dashboard() {
  const { cfg, ccRead, sepRead } = useConfig();
  const [me, setMe] = useState<string | null>(null);
  const [orderId, setOrderId] = useState('1');
  const [localLog, setLocalLog] = useState<LogEntry[]>([]);
  const [workerState, setWorkerState] = useState<WorkerState | null>(null);
  const [panel, setPanel] = useState<PanelKey>('seller');

  const log = useCallback((m: string, cls = '') => {
    setLocalLog(prev => [{ msg: new Date().toLocaleTimeString() + '  ' + m, cls }, ...prev]);
  }, []);

  async function connect() {
    const eth = (window as any).ethereum;
    if (!eth) return alert('Install MetaMask');
    const [a] = await eth.request({ method: 'eth_requestAccounts' });
    const addr = getAddress(a);
    setMe(addr);
    log('connected ' + addr);
  }

  useEffect(() => {
    let cancelled = false;
    async function refresh() {
      try {
        const s = await (await fetch('/state')).json();
        if (!cancelled) setWorkerState(s);
      } catch { /* ignore — matches original's silent catch */ }
    }
    refresh();
    const t = setInterval(refresh, 15000);
    return () => { cancelled = true; clearInterval(t); };
  }, []);

  return (
    <>
      <div className="aura"><i className="a1"></i><i className="a2"></i></div>
      <header>
        <div className="nav">
          <a className="brand" href="/"><BrandMark className="mark" />PayGo</a>
          <span className="tagline">Buy now, pay in installments — escrow on Creditcoin, paid on Ethereum, proven by Attestcoin.</span>
          <button id="connect" onClick={connect}>Connect wallet</button>
          <span id="who" className="mono">{me}</span>
        </div>
      </header>
      {cfg && ccRead && sepRead ? (
        <main>
          <div className="dash-grid">
            <Sidebar active={panel} onSelect={setPanel} />
            <div className="panel-col">
              {panel === 'seller' && <SellerCard cfg={cfg} sepRead={sepRead} me={me} log={log}
                onOrderCreated={id => { setOrderId(id); setPanel('buyer'); }} />}
              {panel === 'buyer' && <BuyerCard cfg={cfg} ccRead={ccRead} me={me} log={log} orderId={orderId} setOrderId={setOrderId} />}
              {panel === 'passport' && <PassportCard cfg={cfg} ccRead={ccRead} me={me} />}
              {panel === 'custody' && <CustodyCard cfg={cfg} ccRead={ccRead} log={log} />}
            </div>
            <div className="pinned-col">
              <TrackerCard cfg={cfg} ccRead={ccRead} log={log} orderId={orderId} setOrderId={setOrderId} />
              <GasChart />
              <WorkerLog state={workerState} localLog={localLog} />
            </div>
          </div>
        </main>
      ) : null}
    </>
  );
}
