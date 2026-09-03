import { CheckCircle2, AlertTriangle, XCircle, Clock, Zap, ShieldCheck, Fingerprint, Circle } from 'lucide-react';
import type { WorkerState } from '../../lib/config';

export interface LogEntry { t: string; msg: string; cls?: string }
type Row = { key: string; Icon: typeof Circle; cls: string; msg: string; t?: string };

const short = (h: string) => h.length > 14 ? h.slice(0, 8) + '…' + h.slice(-4) : h;
const ICON: Record<string, typeof Circle> = { ok: CheckCircle2, warn: AlertTriangle, bad: XCircle };

/** One feed for everything that moved: your own actions, the relayer's autopay, proofs pending and settled. */
export function ActivityFeed({ state, localLog }: { state: WorkerState | null; localLog: LogEntry[] }) {
  const rows: Row[] = localLog.map((l, i) => ({ key: 'l' + i, Icon: ICON[l.cls ?? ''] ?? Circle, cls: l.cls ?? '', msg: l.msg, t: l.t }));
  if (state) {
    const w: Row[] = [];
    for (const a of state.autopay) w.push({ key: 'a' + a.orderId + a.installmentNo, Icon: Zap, cls: a.error ? 'bad' : a.txHash ? 'ok' : '',
      msg: `autopay · order ${a.orderId} #${a.installmentNo} · ${a.txHash ? 'paid ' + short(a.txHash) : a.error ? 'failed: ' + a.error : 'due at ' + new Date(a.validAfter * 1000).toLocaleTimeString()}` });
    for (const p of state.pending) w.push({ key: 'p' + p.hash, Icon: Clock, cls: 'warn', msg: `proof pending · ${short(p.hash)} · Ethereum ${p.height}` });
    for (const p of state.custodyPending || []) w.push({ key: 'c' + p.hash, Icon: Fingerprint, cls: 'warn', msg: `custody proof pending · ${short(p.hash)}` });
    for (const t of state.settles) w.push({ key: 's' + t.tx, Icon: ShieldCheck, cls: 'ok', msg: `settled ${t.count} installment${t.count > 1 ? 's' : ''} · ${short(t.tx)} · ${Math.round(Number(t.gas) / t.count).toLocaleString('en-US')} gas each` });
    rows.push(...w.reverse());
  }
  return (
    <section className="card feed">
      <h2>Activity</h2>
      <div className="desc">Everything that moved: what you did, the installments paying themselves, and every proof as it lands. None of it needs you.</div>
      {rows.length ? (
        <ul className="feed-list">
          {rows.map(r => (
            <li key={r.key} className={r.cls}><r.Icon aria-hidden="true" /><span className="feed-msg">{r.msg}</span>{r.t && <span className="feed-t mono">{r.t}</span>}</li>
          ))}
        </ul>
      ) : (
        <div className="empty-t">Quiet for now. Pay a deposit or switch on autopay, and the proofs show up here.</div>
      )}
    </section>
  );
}
