export type PanelKey = 'seller' | 'buyer' | 'passport' | 'custody';

const PANELS: { key: PanelKey; n: string; label: string }[] = [
  { key: 'seller', n: '1', label: 'Seller' },
  { key: 'buyer', n: '2', label: 'Buyer' },
  { key: 'passport', n: '4', label: 'Passport' },
  { key: 'custody', n: '5', label: 'Custody' },
];

// Dock-style switcher, in-flow with the rest of the page (not viewport-fixed) so it stays inside
// the app's centered 1120px column instead of hugging the true screen edge.
export function Sidebar({ active, onSelect }: { active: PanelKey; onSelect: (k: PanelKey) => void }) {
  return (
    <nav className="dock" aria-label="Switch panel">
      {PANELS.map(p => (
        <button key={p.key} type="button" className={`dock-btn${p.key === active ? ' on' : ''}`}
          onClick={() => onSelect(p.key)} title={p.label} aria-current={p.key === active}>
          <span className="dock-n">{p.n}</span>
          <span className="dock-label">{p.label}</span>
        </button>
      ))}
    </nav>
  );
}
