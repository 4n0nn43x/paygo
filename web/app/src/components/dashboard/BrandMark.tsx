export function BrandMark({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 32 32" fill="none" aria-hidden="true">
      <rect className="rot" x="3" y="3" width="26" height="26" rx="8" stroke="#E9A21A" strokeWidth="2" />
      <circle cx="16" cy="16" r="4.4" fill="#E9A21A" />
    </svg>
  );
}
