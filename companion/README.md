# Companion

The Python process that runs beside each game client. It moves commands from the hub to the in-game bus, and frames from the bus back to the hub. See [docs/plan.md](../docs/plan.md), Phase 1 workstream 5.

| Module | Role |
|---|---|
| `dufleet.protocol` | The reference codec for [protocol v1](../docs/protocol.md): CRC-16, frames, the deframer, commands, dedupe. `generated.py` comes from `packages/protocol/codegen.py` |
| `dufleet.hub` | The `Hub` interface the rest depends on: the RPCs in `supabase/migrations/0003_rpc.sql`, plus state, telemetry and event writes |
| `dufleet.pump` | `CommandPump`, described below |
| `dufleet.router` | `FrameRouter`: checks every frame body against the protocol's JSON Schemas, then passes A and N to the pump, sends H to `sync_epoch` and `bot_report`, writes T to `bot_state` (1 Hz) and `telemetry` (every 5 s), E and D as events, and hands R to the pump |

`CommandPump`:
- recovers the in-flight command after a restart;
- then claims one command at a time and sends its line;
- waits for the matching A or N, retrying after 1, 3 and 8 s;
- records sent, acked, done, failed or failed_delivery;
- keeps a `run` command acked until its job's R frame arrives.

Not here yet:
- the Supabase client behind `Hub` (sign-in as the device user, realtime on `commands` to wake the pump);
- configuration and the CLI (`run`, `install`, `doctor`, `replay`);
- the transports, which wait for ADR-0001.

The probe kit in `spikes/host` already has the log tail, the optical decoder and the inbox writer as spike code.

## Tests

```sh
cd companion
uv run pytest            # the Postgres tests skip unless enabled (below)
uv run ruff check . ../packages/protocol
```

- `tests/fakes.py`: an in-memory hub with the same rules as the SQL, and a bus built from the reference codec that can lose or garble lines.
- `tests/test_lua_bus.py`: runs the real Lua bus (`lua/tools/simulate.lua`, needs lua5.3 and `lua/tools/deps.sh`) and reads its output back.
- `tests/test_pump_pg.py`: runs the pump against the real hub SQL on PostgreSQL. It creates and drops the database `dufleet_pump_test`, so it only runs when asked:

  ```sh
  DUFLEET_PG_TESTS=1 PGHOST=... PGPORT=... PGUSER=postgres uv run pytest
  ```
