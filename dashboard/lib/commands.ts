import { VERBS } from "./protocol.ts";

// Phase 1: the dashboard queues only commands without arguments that cannot move a ship.
export const COMPOSER_VERBS = ["ping", "status"] as const;
export type ComposerVerb = (typeof COMPOSER_VERBS)[number];

export function isComposerVerb(verb: unknown): verb is ComposerVerb {
  return typeof verb === "string" && (COMPOSER_VERBS as readonly string[]).includes(verb) && verb in VERBS;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID.test(value);
}
