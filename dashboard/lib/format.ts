// Compact formatting for dense tables.

export function ago(iso: string | null | undefined, now: number = Date.now()): string {
  if (!iso) return "never";
  const s = Math.max(0, Math.round((now - Date.parse(iso)) / 1000));
  if (s < 90) return `${s} s`;
  if (s < 90 * 60) return `${Math.round(s / 60)} min`;
  if (s < 36 * 3600) return `${Math.round(s / 3600)} h`;
  return `${Math.round(s / 86400)} d`;
}

export function num(x: number | null | undefined, digits = 0): string {
  return x === null || x === undefined || Number.isNaN(x) ? "-" : x.toFixed(digits);
}

export function pct(ratio: number | null | undefined): string {
  return ratio === null || ratio === undefined ? "-" : `${Math.round(ratio * 100)}%`;
}
