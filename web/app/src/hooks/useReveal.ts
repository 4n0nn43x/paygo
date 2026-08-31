import { useEffect, useRef } from 'react';

/** IntersectionObserver reveal/stagger — ported from landing.html's inline script. */
export function useReveal<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(es => {
      es.forEach(e => { if (e.isIntersecting) { el.classList.add('in'); io.unobserve(el); } });
    }, { threshold: 0.14 });
    io.observe(el);
    return () => io.disconnect();
  }, []);
  return ref;
}
