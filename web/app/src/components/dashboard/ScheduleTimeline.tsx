import { useState } from 'react';
import { fmt } from '../../lib/format';

export interface ScheduleStep { no: number; amount: bigint; deadline: bigint; paid: boolean }

// Status track for the installment schedule. Only two states occur here (paid/due — BuyerCard
// never computes "overdue", that lives in TrackerCard), so color (good/neutral) is paired with an
// icon + on-hover label, never color alone — dataviz skill: CVD floor band requires secondary encoding.
export function ScheduleTimeline({ steps }: { steps: ScheduleStep[] }) {
  const [hover, setHover] = useState<number | null>(null);
  if (!steps.length) return null;
  return (
    <div className="sched-timeline" role="img" aria-label={`Installment schedule: ${steps.filter(s => s.paid).length} of ${steps.length} proven`}>
      {steps.map((s, i) => (
        <div key={s.no} className="sched-item">
          <div className={`sched-seg ${s.paid ? 'paid' : 'due'}`} tabIndex={0}
            onPointerEnter={() => setHover(s.no)} onPointerLeave={() => setHover(null)}
            onFocus={() => setHover(s.no)} onBlur={() => setHover(null)}>
            {s.paid ? '✓' : s.no}
            {hover === s.no && (
              <div className="sched-tip" role="tooltip">#{s.no} · {fmt(s.amount)} · height {String(s.deadline)} · {s.paid ? 'proven' : 'due'}</div>
            )}
          </div>
          {i < steps.length - 1 && <div className={`sched-link ${s.paid ? 'on' : ''}`} />}
        </div>
      ))}
    </div>
  );
}
