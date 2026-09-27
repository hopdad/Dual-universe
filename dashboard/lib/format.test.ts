import assert from "node:assert/strict";
import { test } from "node:test";

import { ago, num, pct } from "./format.ts";

test("ago picks a readable unit", () => {
  const now = Date.parse("2026-09-27T12:00:00Z");
  assert.equal(ago("2026-09-27T11:59:48Z", now), "12 s");
  assert.equal(ago("2026-09-27T11:57:00Z", now), "3 min");
  assert.equal(ago("2026-09-27T07:00:00Z", now), "5 h");
  assert.equal(ago("2026-09-20T12:00:00Z", now), "7 d");
  assert.equal(ago(null, now), "never");
  assert.equal(ago("2026-09-27T12:00:05Z", now), "0 s");
});

test("numbers and ratios", () => {
  assert.equal(num(12.345, 1), "12.3");
  assert.equal(num(null), "-");
  assert.equal(pct(0.414), "41%");
  assert.equal(pct(undefined), "-");
});
