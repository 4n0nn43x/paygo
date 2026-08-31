import { useEffect, useRef, useState } from 'react';

const reduce = typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion:reduce)').matches;

// The hero illustration's mini-schedule advances one dot each time the proof coin lands,
// synced to the 3s `travel` CSS animation — ported from landing.html's inline script.
export function MiniSchedule() {
  const [on, setOn] = useState<boolean[]>(reduce ? [true, true, true, true] : [false, false, false, false]);
  const k = useRef(0);
  useEffect(() => {
    if (reduce) return;
    const t = window.setInterval(() => {
      setOn(prev => {
        if (k.current >= prev.length) { k.current = 0; return prev.map(() => false); }
        const next = [...prev];
        next[k.current++] = true;
        return next;
      });
    }, 3000);
    return () => clearInterval(t);
  }, []);
  return <div className="mini" id="mini">{on.map((v, i) => <i key={i} className={v ? 'on' : ''}></i>)}</div>;
}
