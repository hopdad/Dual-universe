# Lua bus

The in-game half of mydu-fleet. It runs inside ArchHUD's control unit (ADR-0002) and speaks [protocol v1](../docs/protocol.md) with the companion.

Everything under `autoconf/custom/` is copied into the game client's `Game/data/lua/autoconf/custom/`, next to ArchHUD 2.105 (The-Third-Verse, commit `6c95222`). Only the companion's `install` does that, and it checks every file by hash.

| File | Role |
|---|---|
| `archhud/userclass.lua` | Shim: ArchHUD loads it last; it attaches, starts and stops the bus, each under `pcall` |
| `dufleet/bus.lua` | Wires the modules: hooks, timer, H and T, draining the outbox |
| `dufleet/archhud_adapter.lua` | The only module that touches ArchHUD: `PROGRAM` hooks, the unit and core in `Nav`, the databank from ArchHUD's constructors, autopilot flags, fuel tanks, target selection, toggle and stop, `userScreen` |
| `dufleet/game.lua` | The game API calls the bus makes: `DUSystem`, `DUConstruct`, and the unit and core from the adapter |
| `dufleet/dispatcher.lua` | Command queue: parse, dedupe, handler, persist, reply |
| `dufleet/builtins.lua` | Handlers for every verb. The job verbs go to the runtime; relay (Phase 3) refuses with `E_STATE` for now |
| `dufleet/runtime.lua` | The skill runtime: one job at a time, `skill_state` events, `R`, pause and cancel, `dub.job` |
| `dufleet/skills/goto.lua` | `goto`: select the target in ArchHUD, toggle its autopilot once, watch for arrival |
| `dufleet/outbox.lua` | Priorities, one pending T, send-time seq, chunk continuation, replay ring |
| `dufleet/persist.lua` | `dub.` keys in ArchHUD's databank (`dbHud_1`), with the watermark in `dub.last` |
| `dufleet/command.lua`, `frame.lua`, `dedupe.lua`, `crc16.lua`, `base64.lua`, `jsonenc.lua` | The codec, identical in behaviour to the Python one |
| `dufleet/protocol_gen.lua` | Generated from `packages/protocol/protocol.schema.json`. Do not edit |

Not here yet: the transports [ADR-0001](../docs/adr/0001-transports.md) chose, the optical frame (O) drawn through `userScreen` and the inbox file (F). Until then, frames go out through `DUSystem.print` into the Lua chat channel, which is enough for manual tests.

## How the bus reaches the game

Files loaded with `require` cannot see the control unit's handler slots: `system`, `unit`, `construct`, `core` and `dbHud_1` are nil there ([verification.md](../docs/verification.md#addendum-in-game-2026-09-28)). So:
- the system and construct APIs are the globals `DUSystem` and `DUConstruct`, as ArchHUD's own classes use them;
- the unit and the core are `Nav.control` and `Nav.core`: ArchHUD.conf builds its global `Nav` with `Navigator.new(system, core, unit)`;
- the databank reaches only ArchHUD's class constructors, during setup. The shim has the adapter wrap the global `AtlasClass` and `APClass` when ArchHUD loads it, before setup runs, and keep what they receive (arguments 5 and 9);
- `ExtraOnStart` runs inside ArchHUD's setup coroutine, where an escaping error would end the setup, so the shim runs every hook under `pcall`.

The fake ArchHUD in the specs hides the handler slots the same way, and luacheck only allows `DUSystem` and `DUConstruct`, so bus code that reads a slot fails both.

## Tests

Needs Lua 5.3 (the game runs 5.4; the code must run on both), [busted](https://lunarmodules.github.io/busted/), luacheck and dkjson (`luarocks install busted luacheck dkjson`, or the distribution packages).

```sh
cd lua
./tools/deps.sh      # du-mocks, ArchHUD and the atlas, pinned, into .deps/
busted               # specs in spec/, including every case in packages/protocol/vectors.json
luacheck .
```

The specs run the bus in a fake ArchHUD (`spec/helpers/fake_archhud.lua`); `h.start()` replays ArchHUD's start: the shim loads, setup calls the constructors with the databank, then `ExtraOnStart`. It uses du-mocks for the control unit, core and databank, and small fakes where du-mocks leaves a call unimplemented. Its atlas and autopilot copy what the pinned ArchHUD source does for the calls `goto` makes, including selecting the location that sorts first and the orbital hop on a quick second toggle. On each tick it flies the ship toward the target, so jobs finish in the simulator too.

`spec/archhud_contract_spec.lua` runs the adapter against ArchHUD's real atlas and autopilot code instead (`spec/helpers/real_archhud.lua`). `tools/deps.sh` fetches The-Third-Verse/ArchHUD (GPL-3.0) and The-Third-Verse/AtlasFile into `.deps/` at the commits pinned in `companion/src/dufleet/pins.py`; nothing of theirs is committed here. Without them the contract spec is pending.

`tools/simulate.lua` runs the same setup from a script on stdin. `companion/tests/test_lua_bus.py` pipes its output through the Python deframer and the JSON Schemas, which checks the two sides against each other end to end.

Busted runs each spec file in its own environment, so a spec that changes an ArchHUD global writes `_G.Name` rather than `Name`.
