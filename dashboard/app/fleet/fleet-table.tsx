"use client";

import Link from "next/link";
import { useEffect, useState } from "react";

import { BotStatusBadge, DriftBadge } from "@/components/badges";
import { drifted, fleetVersion } from "@/lib/drift";
import { ago, num, pct } from "@/lib/format";
import { createClient } from "@/lib/supabase/client";
import type { Bot, BotState } from "@/lib/types";

// Live fleet table: server-rendered rows, then realtime changes on bots and bot_state.
export function FleetTable({ initialBots, initialStates }: { initialBots: Bot[]; initialStates: BotState[] }) {
  const [bots, setBots] = useState(() => new Map(initialBots.map((b) => [b.id, b])));
  const [states, setStates] = useState(() => new Map(initialStates.map((s) => [s.bot_id, s])));
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const supabase = createClient();
    const channel = supabase
      .channel("fleet")
      .on("postgres_changes", { event: "*", schema: "public", table: "bot_state" }, (payload) => {
        if (payload.eventType === "DELETE") return;
        const row = payload.new as BotState;
        setStates((prev) => new Map(prev).set(row.bot_id, row));
      })
      .on("postgres_changes", { event: "*", schema: "public", table: "bots" }, (payload) => {
        if (payload.eventType === "DELETE") {
          const id = (payload.old as Partial<Bot>).id;
          setBots((prev) => {
            const next = new Map(prev);
            if (id) next.delete(id);
            return next;
          });
          return;
        }
        const row = payload.new as Bot;
        setBots((prev) => new Map(prev).set(row.id, { ...prev.get(row.id), ...row }));
      })
      .subscribe();
    const timer = setInterval(() => setNow(Date.now()), 5000);
    return () => {
      clearInterval(timer);
      void supabase.removeChannel(channel);
    };
  }, []);

  const list = [...bots.values()].sort((a, b) => a.short_id.localeCompare(b.short_id));
  const fleetScript = fleetVersion(list.map((b) => b.script_version));
  const fleetHud = fleetVersion(list.map((b) => b.archhud_version));

  if (list.length === 0) return <p className="text-sm text-zinc-500">No bots yet.</p>;
  return (
    <table className="data" data-testid="fleet">
      <thead>
        <tr>
          <th>Bot</th><th>Status</th><th>Skill</th><th>Autopilot</th><th className="text-right">km/h</th>
          <th className="text-right">Alt m</th><th className="text-right">Atmo</th><th className="text-right">Space</th>
          <th className="text-right">Cargo</th><th>Bus</th><th>ArchHUD</th><th>Epoch</th><th>Seen</th><th>State</th>
        </tr>
      </thead>
      <tbody>
        {list.map((bot) => {
          const s = states.get(bot.id);
          return (
            <tr key={bot.id} data-bot={bot.short_id}>
              <td><Link href={`/bots/${bot.id}`} className="font-medium hover:underline">{bot.short_id}</Link></td>
              <td><BotStatusBadge status={bot.status} /></td>
              <td>{s?.skill ? `${s.skill}${s.skill_phase ? `:${s.skill_phase}` : ""}` : "-"}</td>
              <td>{s?.autopilot ?? "-"}</td>
              <td className="text-right" data-field="speed">{num(s?.speed_kmh, 1)}</td>
              <td className="text-right">{num(s?.alt)}</td>
              <td className="text-right">{pct(s?.fuel?.atmo)}</td>
              <td className="text-right">{pct(s?.fuel?.space)}</td>
              <td className="text-right">{pct(s?.cargo_ratio)}</td>
              <td>{bot.script_version ?? "-"}{fleetScript && drifted(bot.script_version, fleetScript) && <DriftBadge fleet={fleetScript} />}</td>
              <td>{bot.archhud_version ?? "-"}{fleetHud && drifted(bot.archhud_version, fleetHud) && <DriftBadge fleet={fleetHud} />}</td>
              <td>{bot.epoch}</td>
              <td>{ago(bot.last_seen, now)}</td>
              <td>{ago(s?.updated_at, now)}</td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}
