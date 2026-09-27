import { notFound } from "next/navigation";

import { BotStatusBadge, CommandStatusBadge } from "@/components/badges";
import { Ago } from "@/components/ago";
import { AutoRefresh } from "@/components/auto-refresh";
import { isUuid } from "@/lib/commands";
import { num, pct } from "@/lib/format";
import { createClient } from "@/lib/supabase/server";
import type { Bot, BotEvent, BotState, Command } from "@/lib/types";

export default async function BotPage(props: PageProps<"/bots/[id]">) {
  const { id } = await props.params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const [bot, state, commands, events] = await Promise.all([
    supabase.from("bots").select("*").eq("id", id).maybeSingle(),
    supabase.from("bot_state").select("*").eq("bot_id", id).maybeSingle(),
    supabase.from("commands").select("*").eq("bot_id", id).order("created_at", { ascending: false }).limit(50),
    supabase.from("events").select("*").eq("bot_id", id).order("ts", { ascending: false }).limit(50),
  ]);
  if (!bot.data) notFound();
  const b = bot.data as Bot;
  const s = state.data as BotState | null;

  return (
    <div className="space-y-6">
      <AutoRefresh seconds={5} />
      <section className="space-y-1">
        <h1 className="flex items-center gap-2 text-base font-semibold">
          {b.short_id} <BotStatusBadge status={b.status} />
        </h1>
        <p className="text-xs text-zinc-500">
          host {b.host ?? "-"} · bus {b.script_version ?? "-"} · ArchHUD {b.archhud_version ?? "-"} · epoch {b.epoch}
          {" "}· boot {b.boot_id ?? "-"} · seen <Ago iso={b.last_seen} /> ago
        </p>
      </section>

      <section>
        <h2 className="mb-1 text-sm font-semibold">State</h2>
        {s ? (
          <table className="data">
            <tbody>
              <tr><th>Position (m)</th><td>{num(s.wx, 1)}, {num(s.wy, 1)}, {num(s.wz, 1)}</td></tr>
              <tr><th>Body, lat, lon</th><td>{s.body_id ?? "-"}, {num(s.lat, 4)}, {num(s.lon, 4)}</td></tr>
              <tr><th>Altitude (m)</th><td>{num(s.alt)}</td></tr>
              <tr><th>Speed (km/h)</th><td>{num(s.speed_kmh, 1)}</td></tr>
              <tr><th>Fuel</th><td>atmo {pct(s.fuel?.atmo)}, space {pct(s.fuel?.space)}, rocket {pct(s.fuel?.rocket)}</td></tr>
              <tr><th>Cargo</th><td>{pct(s.cargo_ratio)}</td></tr>
              <tr><th>Skill</th><td>{s.skill ?? "-"}{s.skill_phase ? `:${s.skill_phase}` : ""}</td></tr>
              <tr><th>Autopilot</th><td>{s.autopilot ?? "-"}</td></tr>
              <tr><th>Updated</th><td><Ago iso={s.updated_at} /> ago</td></tr>
            </tbody>
          </table>
        ) : (
          <p className="text-xs text-zinc-500">No telemetry yet.</p>
        )}
      </section>

      <section>
        <h2 className="mb-1 text-sm font-semibold">Commands</h2>
        <table className="data">
          <thead>
            <tr><th>#</th><th>Verb</th><th>Arguments</th><th>Status</th><th>Tries</th><th>Error</th><th>Queued</th></tr>
          </thead>
          <tbody>
            {((commands.data ?? []) as Command[]).map((c) => (
              <tr key={c.id}>
                <td>{c.epoch}.{c.cseq}</td>
                <td>{c.verb}</td>
                <td className="max-w-80 truncate font-mono">{c.args.join(" ")}</td>
                <td><CommandStatusBadge status={c.status} /></td>
                <td>{c.attempts}</td>
                <td className="max-w-80 truncate">{c.error ?? ""}</td>
                <td><Ago iso={c.created_at} /> ago</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      <section>
        <h2 className="mb-1 text-sm font-semibold">Events</h2>
        <table className="data">
          <thead>
            <tr><th>When</th><th>Kind</th><th>Severity</th><th>Data</th></tr>
          </thead>
          <tbody>
            {((events.data ?? []) as BotEvent[]).map((e) => (
              <tr key={e.id}>
                <td><Ago iso={e.ts} /> ago</td>
                <td>{e.kind}</td>
                <td>{e.severity}</td>
                <td className="max-w-160 truncate font-mono">{JSON.stringify(e.data)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
    </div>
  );
}
