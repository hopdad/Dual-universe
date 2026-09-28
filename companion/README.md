# Companion

The Python process that runs beside each game client. It moves commands from the hub to the in-game bus, and frames from the bus back to the hub. See [docs/plan.md](../docs/plan.md), Phase 1 workstream 5.

| Module | Role |
|---|---|
| `dufleet.protocol` | The reference codec for [protocol v1](../docs/protocol.md): CRC-16, frames, the deframer, commands, dedupe. `generated.py` comes from `packages/protocol/codegen.py` |
| `dufleet.hub` | The `Hub` interface the rest depends on: the RPCs in `supabase/migrations/0003_rpc.sql`, plus state, telemetry and event writes |
| `dufleet.pump` | `CommandPump`, described below |
| `dufleet.supabase_hub` | `SupabaseHub`: the `Hub` on a Supabase project through supabase-py, signed in as the device user. `watch_commands` wakes the pump on realtime inserts |
| `dufleet.router` | `FrameRouter`: checks every frame body against the protocol's JSON Schemas, then passes A and N to the pump, sends H to `sync_epoch` and `bot_report`, writes T to `bot_state` (1 Hz) and `telemetry` (every 5 s), E and D as events, and hands R to the pump |
| `dufleet.config` | The settings file for `dufleet run`, checked with pydantic ([`companion.example.toml`](companion.example.toml)) |
| `dufleet.transport` | The interface for transports: outbound lines in, command lines out. The simulator is the only one until ADR-0001 |
| `dufleet.service` | `serve()`: signs in, starts the transport, and runs the pump and router until stopped |
| `dufleet.gamefiles` | The game's Lua folder: finding it, installing the bus, ArchHUD and the atlas, and checking them by SHA-256 |
| `dufleet.pins` | The pinned ArchHUD and atlas files, the same as the probe kit's |

`CommandPump`:
- recovers the in-flight command after a restart;
- then claims one command at a time and sends its line;
- waits for the matching A or N, retrying after 1, 3 and 8 s;
- records sent, acked, done, failed or failed_delivery;
- keeps a `run` command acked until its job's R frame arrives, and holds an R that overtakes its A (a job that ends at once, or a restart of the bus);
- when T frames have stopped naming a job and its R has not come, asks for a `resend` (`request_resend`), then fails the command as "result lost" if that brings nothing.

`dufleet` on the command line:
- `dufleet cmd VERB [ARGS...]` prints a `/b` line with its CRC, for trying the bus by hand. It keeps a cseq counter in `~/.dufleet/`.
- `dufleet decode [FILE] [--xml]` turns copied chat lines, or the client's XML log, back into JSON messages.
- `dufleet run [--config PATH]` runs the companion for one bot, from a settings file (default `~/.dufleet/companion.toml`; start from [`companion.example.toml`](companion.example.toml)). The device user's password comes from `DUFLEET_DEVICE_PASSWORD`, never the file.
- `dufleet sim --bot BOT_UUID` is `run` with the simulator as the transport: the real Lua bus in its fake ArchHUD (`dufleet.sim.LuaSim`), signed in as the bot's device user. It takes its settings from `DUFLEET_SUPABASE_URL`, `DUFLEET_SUPABASE_KEY`, `DUFLEET_DEVICE_EMAIL` and `DUFLEET_DEVICE_PASSWORD`. Then queue `ping` on the dashboard and watch it come back.
- `dufleet install` puts the bus from `lua/` into the game's Lua folder. With `--archhud fetch` and `--atlas fetch` it also puts in ArchHUD 2.105 and The Third Verse's atlas, checked against their pinned SHA-256; a folder or zip works instead of `fetch`.
  - It is a dry run until you add `--apply`.
  - It backs up every file it replaces or removes under `autoconf/custom/_dufleet_backup/<time>/`. That includes a `userclass.lua` of your own and the probe kit's files.
  - It ends by running `doctor`.
- `dufleet doctor` checks the game folder:
  - ArchHUD and the atlas against their pins;
  - `userclass.lua` is the bus shim;
  - every bus module matches `lua/`.

  It exits 1 if a check fails, and `--json` prints the checks as JSON. Set `DUFLEET_GAME_DIR` (the `Game` folder) or pass `--lua-dir` if the game is not under `C:\ProgramData\My Dual Universe` (spike S8 confirms the path).

Not here yet: the transports for real clients, which wait for ADR-0001. Each is a class with `letter`, `start(on_line)`, `send(line)` and `close()` (`dufleet.transport.Transport`), plus a `kind` in the config.

The probe kit in `spikes/host` already has the log tail, the optical decoder and the inbox writer as spike code.

## Tests

```sh
cd companion
uv run pytest            # the Postgres tests skip unless enabled (below)
uv run ruff check . ../packages/protocol
```

- `tests/fakes.py`: an in-memory hub with the same rules as the SQL, and a bus built from the reference codec that can lose or garble lines.
- `tests/test_lua_bus.py`: runs the real Lua bus (`lua/tools/simulate.lua`, needs lua5.3 and `lua/tools/deps.sh`) and reads its output back.
- `tests/test_supabase_hub.py`: checks `SupabaseHub` against the migrations. Every RPC and parameter it uses must exist, and every column it writes must be one the device may write.
- `tests/test_fullstack_pg.py`: the whole chain without the game: hub SQL, pump and router, and the real Lua bus through `LuaSim`. Round trips stay under the 5 s acceptance bound, and a companion restart mid-command still runs it once.
- `tests/test_pump_pg.py`: runs the pump against the real hub SQL on PostgreSQL. Both Postgres suites create and drop the database `dufleet_pump_test`, so they only run when asked:

  ```sh
  DUFLEET_PG_TESTS=1 PGHOST=... PGPORT=... PGUSER=postgres uv run pytest
  ```
