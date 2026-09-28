import { VERBS } from "./protocol.ts";

// The dashboard queues only commands without required arguments that cannot set a ship moving.
// cancel stops the autopilot and brakes, whether or not a job runs (docs/protocol.md, "Jobs").
export const COMPOSER_VERBS = ["ping", "status", "cancel"] as const;
export type ComposerVerb = (typeof COMPOSER_VERBS)[number];

export const COMPOSER_LABELS: Record<ComposerVerb, string> = {
  ping: "ping",
  status: "status",
  cancel: "cancel: stop and brake",
};

export function isComposerVerb(verb: unknown): verb is ComposerVerb {
  return typeof verb === "string" && (COMPOSER_VERBS as readonly string[]).includes(verb) && verb in VERBS;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID.test(value);
}
