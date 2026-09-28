# Lua bus

The in-game half of mydu-fleet. It runs inside ArchHUD's control unit (ADR-0002) and speaks [protocol v1](../docs/protocol.md) with the companion.

Everything under `autoconf/custom/` is copied into the game client's `Game/data/lua/autoconf/custom/`, next to ArchHUD 2.105 (The-Third-Verse, commit `6c95222`). Only the companion's `install` does that, and it checks every file by hash.

| File | Role |
|---|---|
| `archhud/userclass.lua` | Shim: ArchHUD loads it last; it starts and stops the bus |
| `dufleet/bus.lua` | Wires the modules: hooks, timer, H and T, draining the outbox |
| `dufleet/archhud_adapter.lua` | The only module that touches ArchHUD: `PROGRAM` hooks, `dbHud_1`, autopilot flags, fuel tanks, target selection, toggle and stop, `userScreen` |
| `dufleet/game.lua` | The game API calls the bus makes (`system`, `unit`, `construct`, `core`) |
| `dufleet/dispatcher.lua` | Command queue: parse, dedupe, handler, persist, reply |
| `dufleet/builtins.lua` | Handlers for every verb. The job verbs go to the runtime; relay (Phase 3) refuses with `E_STATE` for now |
| `dufleet/runtime.lua` | The skill runtime: one job at a time, `skill_state` events, `R`, pause and cancel, `dub.job` |
| `dufleet/skills/goto.lua` | `goto`: select the target in ArchHUD, toggle its autopilot once, watch for arrival |
| `dufleet/outbox.lua` | Priorities, one pending T, send-time seq, chunk continuation, replay ring |
| `dufleet/persist.lua` | `dub.` keys in `dbHud_1`, with the watermark in `dub.last` |
| `dufleet/command.lua`, `frame.lua`, `dedupe.lua`, `crc16.lua`, `base64.lua`, `jsonenc.lua` | The codec, identical in behaviour to the Python one |
| `dufleet/protocol_gen.lua` | Generated from `packages/protocol/protocol.schema.json`. Do not edit |

Not here yet, and waiting on ADR-0001:
- the optical transport (O), which would draw frames through `userScreen`;
- the inbox (F).

Until then, frames go out through `system.print` (Transport L). They show up in the Lua chat channel, which is enough for manual tests.

## Tests

Needs Lua 5.3, [busted](https://lunarmodules.github.io/busted/), luacheck and dkjson (`luarocks install busted luacheck dkjson`, or the distribution packages).

```sh
cd lua
./tools/deps.sh      # du-mocks, ArchHUD and the atlas, pinned, into .deps/
busted               # specs in spec/, including every case in packages/protocol/vectors.json
luacheck .
```

The specs run the bus in a fake ArchHUD (`spec/helpers/fake_archhud.lua`). It uses du-mocks for the control unit, core and databank, and small fakes where du-mocks leaves a call unimplemented. Its atlas and autopilot copy what the pinned ArchHUD source does for the calls `goto` makes, including selecting the location that sorts first and the orbital hop on a quick second toggle. On each tick it flies the ship toward the target, so jobs finish in the simulator too.

`spec/archhud_contract_spec.lua` runs the adapter against ArchHUD's real atlas and autopilot code instead (`spec/helpers/real_archhud.lua`). `tools/deps.sh` fetches The-Third-Verse/ArchHUD (GPL-3.0) and The-Third-Verse/AtlasFile into `.deps/` at the commits pinned in `companion/src/dufleet/pins.py`; nothing of theirs is committed here. Without them the contract spec is pending.

`tools/simulate.lua` runs the same setup from a script on stdin. `companion/tests/test_lua_bus.py` pipes its output through the Python deframer and the JSON Schemas, which checks the two sides against each other end to end.

Busted runs each spec file in its own environment, so a spec that changes an ArchHUD global writes `_G.Name` rather than `Name`.
