// Hero illustration: an abstract schedule clock. Thin rings, 60 graduations, the outer ring split into
// N installment slots: the proven ones draw themselves in gold one after another (the only focal
// motion), the rest stay faint. A dashed ring and a single marker drift very slowly behind it: time
// keeps attesting whether you pay or not. Pure SVG + CSS, no library; reduced motion = final frame.
const C = 260, R_OUT = 236, R_MID = 176, R_IN = 112;
const SLOTS = 6, PROVEN = 4;
const TICKS = Array.from({ length: 60 }, (_, i) => i);
const SEGS = Array.from({ length: SLOTS }, (_, i) => i);

export function Dial() {
  return (
    <div className="dial-wrap">
      <svg className="dial" viewBox="0 0 520 520" aria-hidden="true">
        <g className="dial-grid">
          <line x1={C} y1="0" x2={C} y2="520" />
          <line x1="0" y1={C} x2="520" y2={C} />
        </g>
        <g className="dial-ticks">
          {TICKS.map(i => {
            const major = i % 5 === 0;
            return <line key={i} x1={C} y1={C - R_OUT + 2} x2={C} y2={C - R_OUT + (major ? 14 : 7)}
              transform={`rotate(${i * 6} ${C} ${C})`} className={major ? 'major' : undefined} />;
          })}
        </g>
        <circle className="dial-ring" cx={C} cy={C} r={R_OUT} />
        <circle className="dial-ring dial-dash" cx={C} cy={C} r={R_MID} />
        <circle className="dial-ring" cx={C} cy={C} r={R_IN} />
        <g className="dial-marker"><circle cx={C} cy={C - R_IN} r="3.5" /></g>
        {/* installment slots on the outer ring, from 12 o'clock clockwise; pathLength = SLOTS so one slot = 1 unit */}
        {SEGS.map(i => (
          <circle key={i} className={i < PROVEN ? 'dial-seg on' : 'dial-seg'} cx={C} cy={C} r={R_OUT}
            pathLength={SLOTS} transform={`rotate(${-90 + i * (360 / SLOTS)} ${C} ${C})`}
            style={i < PROVEN ? { animationDelay: `${0.7 + i * 0.55}s` } : undefined} />
        ))}
        <circle className="dial-core" cx={C} cy={C} r="4" />
      </svg>
      <div className="dial-legend">
        <span><b>{PROVEN} / {SLOTS}</b> installments proven</span>
        <span>next deadline <b>epoch +2</b></span>
      </div>
    </div>
  );
}
