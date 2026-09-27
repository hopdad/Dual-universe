import assert from "node:assert/strict";
import { test } from "node:test";

import { compareVersions, drifted, fleetVersion } from "./drift.ts";

test("versions compare numerically", () => {
  assert.ok(compareVersions("0.10.0", "0.9.9") > 0);
  assert.ok(compareVersions("2.105", "2.104") > 0);
  assert.equal(compareVersions("1.0", "1.0.0"), 0);
});

test("the fleet version is the most common, ties to the higher", () => {
  assert.equal(fleetVersion(["0.1.0", "0.1.0", "0.2.0", null]), "0.1.0");
  assert.equal(fleetVersion(["0.1.0", "0.2.0"]), "0.2.0");
  assert.equal(fleetVersion(["0.2.0", "0.1.0"]), "0.2.0");
  assert.equal(fleetVersion([null, undefined]), null);
});

test("only a known version that differs counts as drift", () => {
  assert.equal(drifted("0.1.0", "0.2.0"), true);
  assert.equal(drifted("0.2.0", "0.2.0"), false);
  assert.equal(drifted(null, "0.2.0"), false);
  assert.equal(drifted("0.1.0", null), false);
});
