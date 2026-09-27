// Version drift: the fleet's version is the one most bots report; a bot on any other
// version gets a badge. Ties go to the higher version.

export function compareVersions(a: string, b: string): number {
  const pa = a.split(".").map((n) => Number.parseInt(n, 10) || 0);
  const pb = b.split(".").map((n) => Number.parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d;
  }
  return 0;
}

export function fleetVersion(versions: Array<string | null | undefined>): string | null {
  const counts = new Map<string, number>();
  for (const v of versions) if (v) counts.set(v, (counts.get(v) ?? 0) + 1);
  let best: string | null = null;
  let bestCount = 0;
  for (const [v, n] of counts) {
    if (n > bestCount || (n === bestCount && best !== null && compareVersions(v, best) > 0)) {
      best = v;
      bestCount = n;
    }
  }
  return best;
}

export function drifted(version: string | null | undefined, fleet: string | null): boolean {
  return Boolean(version && fleet && version !== fleet);
}
