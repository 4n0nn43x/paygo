import type { ReactNode } from 'react';
import { useSpotlight } from '../../hooks/useSpotlight';

// `hoverable` MUST be a class on the same element as `card`/`light`/`dark` - the CSS
// spotlight overlay (`.hoverable::after{border-radius:inherit}`) inherits from that element.
export function MechanismCard({ variant, icon, title, desc, tag }: {
  variant: 'light' | 'dark'; icon: ReactNode; title: string; desc: string; tag: string;
}) {
  const ref = useSpotlight<HTMLDivElement>();
  return (
    <div ref={ref} className={`card ${variant} hoverable`}>
      <div className="ico">{icon}</div>
      <div><h3>{title}</h3><p>{desc}</p></div>
      <div className="chip">{tag}</div>
    </div>
  );
}
