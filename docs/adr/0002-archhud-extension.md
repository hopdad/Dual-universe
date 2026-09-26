# ADR-0002: Fly with ArchHUD and run the bot bus inside it

- Status: Accepted, 2026-09-26. Confirm on the target server in spikes A1, A2 and S10.
- Decides: gate D1 in [plan.md](../plan.md). Replaces the handoff's Saga fork.

## Context

- The project owner prefers ArchHUD, and any flight script is acceptable because it is a local install.
- Saga left no room for our code: its pasted build uses 99% of the paste limit, and it owns the HUD ([verification.md](../verification.md), findings 2 and 3).
- ArchHUD works differently (evidence in [verification.md](../verification.md#addendum-archhud)):
  - Its modules (about 467 KB) are local files under `Game/data/lua/autoconf/custom/archhud/`, loaded with `require`, so the paste limit does not apply.
  - It loads an optional `archhud/userclass.lua` last. That file can add code to the end of start, stop, update and flush (`userBase.ExtraOn*`), and replace any class function by name (`userAP`, `userControl`, `userHud`, ...).
  - A global `userScreen` is added to the content ArchHUD passes to `system.setScreen`.
  - Its autopilot covers standard ships as well as VTOL: same-planet travel with altitude hold and landing, planet-to-planet flight, orbit, reentry and routes.
- Upstream (Archaegeo, 2.103) has had no commits since 2023-10-02. The samedicorp fork (2.105) adds myDU changes: a custom atlas, new fuel tank types, and a property-saving fix. Its last code change was 2024-11-15.

## Decision

1. Flight script: ArchHUD, from the samedicorp fork, pinned to commit `6c95222`.
2. The bot bus runs inside the ArchHUD control unit. ArchHUD itself stays unmodified:
   - a small `archhud/userclass.lua` shim requires our modules from `autoconf/custom/dufleet/`;
   - at start, the shim wraps `PROGRAM.controlInput` (chat) and `PROGRAM.onTick` (our own timer tag).
3. `goto` calls ArchHUD in-process: `ATLAS.AddNewLocation(name, worldPos, true)`, then `AP.ToggleAutopilot()`. Progress comes from ArchHUD's globals and `construct`.
4. The optical frame, if ADR-0001 needs it, is drawn through `userScreen`.

## Consequences

- No paste-size limit and no DU-LuaC dependency for the bus. It is plain Lua 5.3, tested with busted, du-mocks and a fake-ArchHUD harness.
- The bus depends on ArchHUD globals (`AP`, `ATLAS`, `PROGRAM`, `Autopilot`, `VectorToTarget`, ...), which may change between versions. Keep the adapter in one module, pin the fork commit, and cover the adapter with contract tests.
- The bus must see `/b` lines before ArchHUD does. ArchHUD treats any chat line containing `::pos` as an add-waypoint command, so `/b` arguments never contain the literal `::pos`.
- Never call `AP.ToggleAutopilot()` twice within 1.5 s. In atmosphere, ArchHUD reads a double call as a request for an orbital hop.
- The bus shares ArchHUD's instruction budget. ArchHUD runs a 60 Hz autopilot timer and redraws the HUD at 15 Hz by default. Spike S10 measures the headroom.
- Errors in handlers are printed, not fatal (`__wrap_lua__stopOnError=false`). A CPU overload still stops the unit, so the bus must stay light.
- ArchHUD is GPL-3.0 and the bus runs in the same Lua VM. If the bus is ever distributed, license it GPL-3.0.
- Every bot host needs ArchHUD and the bus installed at the pinned versions. The companion's `doctor` command checks file hashes.
