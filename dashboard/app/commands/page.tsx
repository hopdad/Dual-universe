import Link from "next/link";

import { Ago } from "@/components/ago";
import { AutoRefresh } from "@/components/auto-refresh";
import { CommandStatusBadge } from "@/components/badges";
import { COMPOSER_LABELS, COMPOSER_VERBS } from "@/lib/commands";
import { createClient } from "@/lib/supabase/server";
import type { Command } from "@/lib/types";

import { queueCommand } from "./actions";

const ERRORS: Record<string, string> = {
  input: "Pick a bot and a command.",
  insert: "The hub refused the command.",
};

type Row = Command & { bots: { short_id: string } | null };

export default async function CommandsPage(props: PageProps<"/commands">) {
  const query = await props.searchParams;
  const supabase = await createClient();
  const [bots, commands] = await Promise.all([
    supabase.from("bots").select("id, short_id").order("short_id"),
    supabase.from("commands").select("*, bots(short_id)").order("created_at", { ascending: false }).limit(100),
  ]);
  const error = typeof query.error === "string" ? ERRORS[query.error] : undefined;

  return (
    <div className="space-y-4">
      <AutoRefresh seconds={5} />
      <h1 className="text-base font-semibold">Commands</h1>
      <form action={queueCommand} className="flex items-end gap-2 text-sm">
        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-500">Bot</span>
          <select name="bot" required className="rounded border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-900">
            {(bots.data ?? []).map((b) => <option key={b.id} value={b.id}>{b.short_id}</option>)}
          </select>
        </label>
        <label className="flex flex-col gap-1">
          <span className="text-xs text-zinc-500">Command</span>
          <select name="verb" className="rounded border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-900">
            {COMPOSER_VERBS.map((v) => <option key={v} value={v}>{COMPOSER_LABELS[v]}</option>)}
          </select>
        </label>
        <button type="submit" className="rounded bg-zinc-900 px-3 py-1 text-white dark:bg-zinc-100 dark:text-zinc-900">Queue</button>
      </form>
      {error && <p role="alert" className="text-sm text-red-600">{error}</p>}
      <table className="data">
        <thead>
          <tr><th>Bot</th><th>#</th><th>Verb</th><th>Status</th><th>Tries</th><th>Error</th><th>By</th><th>Queued</th><th>Took</th></tr>
        </thead>
        <tbody>
          {((commands.data ?? []) as Row[]).map((c) => (
            <tr key={c.id}>
              <td><Link href={`/bots/${c.bot_id}`} className="hover:underline">{c.bots?.short_id ?? c.bot_id}</Link></td>
              <td>{c.epoch}.{c.cseq}</td>
              <td>{c.verb}</td>
              <td><CommandStatusBadge status={c.status} /></td>
              <td>{c.attempts}</td>
              <td className="max-w-80 truncate">{c.error ?? ""}</td>
              <td>{c.created_by}</td>
              <td><Ago iso={c.created_at} /> ago</td>
              <td>{c.finished_at ? `${((Date.parse(c.finished_at) - Date.parse(c.created_at)) / 1000).toFixed(1)} s` : ""}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
