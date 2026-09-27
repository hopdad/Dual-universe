import type { BotStatus, CommandStatus } from "@/lib/types";

const BOT: Record<BotStatus, string> = {
  ready: "bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-200",
  busy: "bg-sky-100 text-sky-800 dark:bg-sky-900 dark:text-sky-200",
  in_world: "bg-sky-100 text-sky-800 dark:bg-sky-900 dark:text-sky-200",
  launching: "bg-zinc-200 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  login: "bg-zinc-200 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  offline: "bg-zinc-200 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400",
  degraded: "bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200",
  crashed: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200",
};

const COMMAND: Record<CommandStatus, string> = {
  queued: "bg-zinc-200 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  claimed: "bg-sky-100 text-sky-800 dark:bg-sky-900 dark:text-sky-200",
  sent: "bg-sky-100 text-sky-800 dark:bg-sky-900 dark:text-sky-200",
  acked: "bg-indigo-100 text-indigo-800 dark:bg-indigo-900 dark:text-indigo-200",
  done: "bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-200",
  failed: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200",
  failed_delivery: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200",
  cancelled: "bg-zinc-200 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400",
};

export function BotStatusBadge({ status }: { status: BotStatus }) {
  return <span className={`badge ${BOT[status] ?? ""}`}>{status.replace("_", " ")}</span>;
}

export function CommandStatusBadge({ status }: { status: CommandStatus }) {
  return <span className={`badge ${COMMAND[status] ?? ""}`}>{status.replace("_", " ")}</span>;
}

export function DriftBadge({ fleet }: { fleet: string }) {
  return (
    <span className="badge ml-1 bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200" title={`fleet runs ${fleet}`}>
      drift
    </span>
  );
}
