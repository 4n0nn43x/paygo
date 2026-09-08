import { useEffect, useState } from 'react';
import { Store, ShoppingBag, Fingerprint } from 'lucide-react';

export type PanelKey = 'seller' | 'buyer' | 'custody';

const PANELS: { key: PanelKey; label: string; Icon: typeof Store }[] = [
  { key: 'seller', label: 'Sell', Icon: Store },
  { key: 'buyer', label: 'Buy', Icon: ShoppingBag },
  { key: 'custody', label: 'Custody', Icon: Fingerprint },
];

// macOS-style dock: icon + label, neighbours magnify with the hovered icon (pure CSS, :has),
// a small dot under the active one. Desktop: in-flow, sticky, vertically centred. Phone
// (<=560px, see dashboard.css): a floating bar pinned to the bottom, above the content,
// which slides away while scrolling down and comes back on the way up.

/** Scrolling down hides the dock, scrolling up brings it back. Returns false on desktop too,
 *  which costs nothing: `.hid` only does anything inside the phone media query. */
function useHideOnScrollDown() {
  const [hidden, setHidden] = useState(false);
  useEffect(() => {
    let last = window.scrollY;
    const onScroll = () => {
      const y = window.scrollY;
      if (Math.abs(y - last) < 8) return;      // ignore le tremblement du doigt / rebond iOS
      setHidden(y > last && y > 120);          // masqué en descendant, jamais près du haut
      last = y;
    };
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);
  return hidden;
}

export function Dock({ active, onSelect }: { active: PanelKey; onSelect: (k: PanelKey) => void }) {
  const hidden = useHideOnScrollDown();
  return (
    <div className={`dock-col${hidden ? ' hid' : ''}`}><nav className="dock" aria-label="Role">
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
