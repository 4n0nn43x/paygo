import { useSpotlight } from '../../hooks/useSpotlight';
import { useCountUp } from '../../hooks/useCountUp';

/** The one stat with two count-up numbers ("0 / 76") — doesn't fit StatCard's single-value shape. */
export function RatioStatCard({ a, b, label }: { a: number; b: number; label: string }) {
  const spotRef = useSpotlight<HTMLDivElement>();
  const aRef = useCountUp(a);
  const bRef = useCountUp(b);
  return (
    <div ref={spotRef} className="stat hoverable">
      <div className="n"><span ref={aRef}>0</span> / <span ref={bRef}>0</span></div>
      <div className="l">{label}</div>
    </div>
  );
}
