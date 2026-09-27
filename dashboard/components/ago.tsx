"use client";

import { useEffect, useState } from "react";

import { ago } from "@/lib/format";

// "12 s", "3 min" ...: relative to the viewer's clock, refreshed every 5 s.
export function Ago({ iso }: { iso: string | null | undefined }) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 5000);
    return () => clearInterval(timer);
  }, []);
  return (
    <time dateTime={iso ?? undefined} title={iso ?? undefined} suppressHydrationWarning>
      {ago(iso, now)}
    </time>
  );
}
