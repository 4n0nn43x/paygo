import type { WorkerState } from '../../lib/config';

export interface LogEntry { msg: string; cls?: string }

// Note: the original vanilla-JS version's local log() messages (connect, order created, tx sent…)
// got silently wiped by the next 15s /state poll (replaceChildren overwrote the whole panel) — a side
// effect of two independent DOM writers, not a deliberate behavior. Here local entries persist
// alongside the polled ones instead of flickering away; documented as an intentional, minor deviation.
export function WorkerLog({ state, localLog }: { state: WorkerState | null; localLog: LogEntry[] }) {
  const lines: LogEntry[] = [];
  if (state) {
    for (const a of state.autopay) lines.push({ msg: `autopay order ${a.orderId} #${a.installmentNo} ${a.txHash ? 'paid ' + a.txHash : a.error ? 'failed: ' + a.error : 'due at ' + new Date(a.validAfter * 1000).toLocaleTimeString()}` });
    for (const p of state.pending) lines.push({ msg: `pending proof for ${p.hash} (Sepolia ${p.height})` });
    for (const t of state.settles) lines.push({ msg: `settled ${t.count} installment(s) in ${t.tx} — ${t.gas} gas (${Math.round(Number(t.gas) / t.count)} each)` });
    for (const p of state.custodyPending || []) lines.push({ msg: `pending custody proof for ${p.hash} (Sepolia ${p.height})` });
  }
  const shown = [...localLog, ...lines.reverse()];
  return (
    <section className="card" id="log"><h2><span className="n">◇</span> Worker</h2>
      <div id="log-body" className="mono">
        {shown.length ? shown.map((l, i) => <div key={i} className={l.cls}>{l.msg}</div>) : <div>idle</div>}
      </div>
    </section>
  );
}
