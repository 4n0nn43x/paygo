import { useSpotlight } from '../../hooks/useSpotlight';
import { useCountUp } from '../../hooks/useCountUp';

export function StatCard({ hot, value, sep, unit, prefix, suffix, label }: {
  hot?: boolean; value: number; sep?: boolean; unit?: string; prefix?: string; suffix?: string; label: string;
}) {
  const spotRef = useSpotlight<HTMLDivElement>();
  const countRef = useCountUp(value, sep);
  return (
    <div ref={spotRef} className={`stat hoverable${hot ? ' hot' : ''}`}>
      <div className="n">{prefix}<span ref={countRef}>0</span>{suffix}{unit && <span className="u">{unit}</span>}</div>
      <div className="l">{label}</div>
    </div>
  );
}
