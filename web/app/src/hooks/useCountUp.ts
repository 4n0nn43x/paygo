import { useEffect, useRef } from 'react';

const reduce = typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion:reduce)').matches;

function fmt(n: number, sep: boolean) {
  n = Math.round(n);
  return sep ? n.toLocaleString('en-US') : String(n);
}

/** Count-up-on-scroll for a stat number. */
export function useCountUp(to: number, sep = false) {
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (reduce) { el.textContent = fmt(to, sep); return; }
    const io = new IntersectionObserver(es => {
      es.forEach(e => {
        if (!e.isIntersecting) return;
        io.unobserve(el);
        let t0: number | null = null;
        const dur = 1100;
        function step(ts: number) {
          if (t0 === null) t0 = ts;
          const p = Math.min((ts - t0) / dur, 1);
          const eased = 1 - Math.pow(1 - p, 3);
          el!.textContent = fmt(to * eased, sep);
          if (p < 1) requestAnimationFrame(step);
        }
        requestAnimationFrame(step);
      });
    }, { threshold: 0.6 });
    io.observe(el);
    return () => io.disconnect();
  }, [to, sep]);
  return ref;
}
