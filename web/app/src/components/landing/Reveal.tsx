import type { ReactNode } from 'react';
import { useReveal } from '../../hooks/useReveal';

export function Reveal({ as: As = 'div', className = '', children }: { as?: any; className?: string; children: ReactNode }) {
  const ref = useReveal<HTMLDivElement>();
  return <As ref={ref} className={`reveal ${className}`}>{children}</As>;
}

export function Stagger({ as: As = 'div', className = '', children }: { as?: any; className?: string; children: ReactNode }) {
  const ref = useReveal<HTMLDivElement>();
  return <As ref={ref} className={`stagger ${className}`}>{children}</As>;
}
