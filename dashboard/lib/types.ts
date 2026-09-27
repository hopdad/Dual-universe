// Row shapes of the hub tables (supabase/migrations/0001_core.sql) that the dashboard reads.

export type BotStatus = "offline" | "launching" | "login" | "in_world" | "ready" | "busy" | "degraded" | "crashed";

export type CommandStatus =
  | "queued" | "claimed" | "sent" | "acked" | "done" | "failed" | "failed_delivery" | "cancelled";

export interface Bot {
  id: string;
  short_id: string;
  host: string | null;
  status: BotStatus;
  script_version: string | null;
  archhud_version: string | null;
  boot_id: string | null;
  epoch: number;
  last_seen: string | null;
}

export interface BotState {
  bot_id: string;
  wx: number | null;
  wy: number | null;
  wz: number | null;
  body_id: number | null;
  lat: number | null;
  lon: number | null;
  alt: number | null;
  speed_kmh: number | null;
  fuel: Record<string, number> | null;
  cargo_ratio: number | null;
  skill: string | null;
  skill_phase: string | null;
  autopilot: string | null;
  updated_at: string;
}

export interface Command {
  id: string;
  bot_id: string;
  epoch: number;
  cseq: number;
  verb: string;
  args: string[];
  job_id: string | null;
  status: CommandStatus;
  attempts: number;
  error: string | null;
  result: unknown;
  created_by: string;
  created_at: string;
  finished_at: string | null;
}

export interface BotEvent {
  id: number;
  bot_id: string | null;
  ts: string;
  kind: string;
  severity: number;
  data: Record<string, unknown>;
}
