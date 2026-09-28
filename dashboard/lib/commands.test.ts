import assert from "node:assert/strict";
import { test } from "node:test";

import { COMPOSER_VERBS, isComposerVerb, isUuid } from "./commands.ts";
import { VERBS } from "./protocol.ts";

test("composer verbs exist in the protocol and need no arguments", () => {
  for (const verb of COMPOSER_VERBS) {
    assert.ok(verb in VERBS, verb);
    const args: readonly { optional?: boolean }[] = VERBS[verb].args;
    assert.ok(args.every((a) => a.optional === true), verb);
  }
});

test("nothing that sets a ship moving can be queued", () => {
  for (const verb of ["run", "resume", "relay", "db"]) assert.equal(isComposerVerb(verb), false, verb);
  assert.equal(isComposerVerb("cancel"), true);
});

test("only composer verbs pass", () => {
  assert.equal(isComposerVerb("ping"), true);
  assert.equal(isComposerVerb("run"), false);
  assert.equal(isComposerVerb("toString"), false);
  assert.equal(isComposerVerb(undefined), false);
});

test("bot ids must be uuids", () => {
  assert.equal(isUuid("22222222-0000-0000-0000-000000000001"), true);
  assert.equal(isUuid("hauler-1"), false);
});
