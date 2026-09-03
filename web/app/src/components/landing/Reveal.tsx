import type { ReactNode } from 'react';
import { useReveal } from '../../hooks/useReveal';

/** Adds `in` once scrolled into view. Callers pass the CSS mode in className: `reveal …` or `stagger …`. */
export function Reveal({ as: As = 'div', className, children }: { as?: any; className: string; children: ReactNode }) {
  const ref = useReveal<HTMLDivElement>();
  return <As ref={ref} className={className}>{children}</As>;
}
