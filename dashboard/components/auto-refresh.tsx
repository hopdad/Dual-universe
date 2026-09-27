"use client";

import { useRouter } from "next/navigation";
import { useEffect } from "react";

// Re-renders the current server page every few seconds (command lists change as the pump works).
export function AutoRefresh({ seconds }: { seconds: number }) {
  const router = useRouter();
  useEffect(() => {
    const timer = setInterval(() => router.refresh(), seconds * 1000);
    return () => clearInterval(timer);
  }, [router, seconds]);
  return null;
}
