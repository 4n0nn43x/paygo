import { useState } from 'react';

// Real measured numbers from README.md's "Measured on CC3 testnet" table — not estimates.
const DATA = [
  { key: 'solo', label: 'Solo', gas: 357476, note: '1 fresh proof, first installment' },
  { key: 'batch3', label: 'Batch of 3', gas: 176139, note: 'one continuity proof' },
  { key: 'batch4', label: 'Batch of 4', gas: 159912, note: 'one continuity proof' },
] as const;
const BASELINE = DATA[0].gas;
const MAX = DATA[0].gas;

// Single hue (the app's own gold accent) — these three bars are one measured quantity across
// scenarios, not distinct identities, so no categorical color-coding is needed at all.
export function GasChart() {
  const [hover, setHover] = useState<string | null>(null);
  return (
    <section className="card" id="gas-chart">
      <h2><span className="n">◇</span> Gas per installment</h2>
      <div className="desc">Measured on CC3 testnet, not estimated — batching is the lever.</div>
      <div className="gas-bars" role="img" aria-label="Bar chart: gas per installment, solo versus batched settlement">
        {DATA.map(d => {
          const pct = Math.max(6, Math.round((d.gas / MAX) * 100));
          const savings = Math.round((1 - d.gas / BASELINE) * 100);
          return (
            <div key={d.key} className="gas-bar-col" tabIndex={0}
              onPointerEnter={() => setHover(d.key)} onPointerLeave={() => setHover(null)}
              onFocus={() => setHover(d.key)} onBlur={() => setHover(null)}>
              <div className="gas-bar-value">{d.gas.toLocaleString('en-US')}{savings > 0 && <span className="gas-bar-save"> −{savings}%</span>}</div>
              <div className="gas-bar-track"><div className="gas-bar-fill" style={{ height: pct + '%' }} /></div>
              <div className="gas-bar-label">{d.label}</div>
              {hover === d.key && (
                <div className="gas-tip" role="tooltip">{d.gas.toLocaleString('en-US')} gas · {d.note}{savings > 0 ? ` · ${savings}% below solo` : ' · baseline'}</div>
              )}
            </div>
          );
        })}
      </div>
      <details className="gas-table-toggle"><summary>Table view</summary>
        <table><tbody>
          <tr><th>scenario</th><th>gas / installment</th><th>vs solo</th></tr>
          {DATA.map(d => <tr key={d.key}><td>{d.label}</td><td>{d.gas.toLocaleString('en-US')}</td><td>{d.gas === BASELINE ? '—' : `−${Math.round((1 - d.gas / BASELINE) * 100)}%`}</td></tr>)}
        </tbody></table>
      </details>
    </section>
  );
}
