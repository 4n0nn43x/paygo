// The label list is rendered twice back-to-back so the CSS `mq` keyframe (translateX(-50%))
// loops seamlessly — same pattern as the original markup.
export function Marquee({ items }: { items: string[] }) {
  return (
    <div className="mq-track">
      {items.map((s, i) => <span key={'a' + i}>{s}</span>)}
      {items.map((s, i) => <span key={'b' + i}>{s}</span>)}
    </div>
  );
}
