import { Store, ShoppingBag, Fingerprint } from 'lucide-react';

export type PanelKey = 'seller' | 'buyer' | 'custody';

const PANELS: { key: PanelKey; label: string; Icon: typeof Store }[] = [
  { key: 'seller', label: 'Sell', Icon: Store },
  { key: 'buyer', label: 'Buy', Icon: ShoppingBag },
  { key: 'custody', label: 'Custody', Icon: Fingerprint },
];

// macOS-style dock: icon + label, neighbours magnify with the hovered icon (pure CSS, :has),
// a small dot under the active one. In-flow, sticky and vertically centred, not viewport-fixed.
export function Dock({ active, onSelect }: { active: PanelKey; onSelect: (k: PanelKey) => void }) {
  return (
    <div className="dock-col"><nav className="dock" aria-label="Role">
      {PANELS.map(({ key, label, Icon }) => (
        <button key={key} type="button" className={`dock-btn${key === active ? ' on' : ''}`}
          onClick={() => onSelect(key)} aria-current={key === active}>
          <Icon strokeWidth={1.75} aria-hidden="true" />
          <span className="dock-label">{label}</span>
        </button>
      ))}
    </nav></div>
  );
}
