export function fmt(x: bigint | number): string {
  return (Number(x) / 1e6).toFixed(2) + ' tUSDC';
}
