# Hub (Supabase)

SQL migrations for the mydu-fleet hub. They replace the handoff's `0001`–`0004` and include every fix from [docs/verification.md](../docs/verification.md) (`docs/verification/sql/0005_fixes.sql`), plus the lease and recovery the verification left open.

| Migration | Contents |
|---|---|
| `0001_core.sql` | Types, tables, and the triggers that number commands, keep them immutable, and set event ownership and `updated_at` |
| `0002_rls.sql` | Row level security on every table, and grants down to the column |
| `0003_rpc.sql` | `claim_next_command`, `recover_inflight`, `command_progress`, `cancel_command`, `bot_report`, `sync_epoch` |
| `0004_realtime.sql` | The `supabase_realtime` publication (`telemetry` stays out) |
| `0005_retention.sql` | pg_cron jobs: telemetry after 7 days, minor events after 30, finished commands after 90 |

The tables live in `public`, so use a Supabase project of their own (open question 1 in the plan). There is no `config.toml` yet: `supabase init` creates one once the hosting is chosen. Until then, apply the files in order with `supabase db push` or `psql`.

## Who can do what

Everyone signs in; nothing uses the service role.

| | Owner (dashboard, planner) | Device (one companion login per bot, `bots.device_user_id`) |
|---|---|---|
| `servers`, `goals` | Read and write their own | – |
| `bots` | Create, rename, delete, set `device_user_id` | Read its own bot; report through `bot_report` |
| `commands` | Queue commands (bot, verb, args, job, goal); cancel through `cancel_command` | Read; move through `claim_next_command`, `recover_inflight`, `command_progress` |
| `bot_state`, `telemetry` | Read | Write for its own bot |
| `events` | Read; write events without a bot | Write for its own bot; events belong to the bot's owner |
| `skills` | Read | Read |
| `command_seq` | – | – |

Clients never set `epoch`, `cseq`, `status`, timestamps or ownership: the column grants leave them out, and triggers fill them in.

## Commands

```
queued ──claim──> claimed ──> sent ──> acked ──> done
   │                 │          │         └────> failed
   │                 └──────────┴──> acked, done, failed, failed_delivery
   └──cancel_command──> cancelled          (sync_epoch also cancels old queued ones)
```

- The insert trigger gives each command its bot's current `epoch` and next `cseq`. After that, the bot, epoch, cseq, verb, args and job never change, even for the database owner.
- `args` is a JSON array of strings, in the order they go on the command line (`docs/protocol.md`).
- One command per bot is in flight (`claimed` or `sent`). `claim_next_command(bot, lease_s default 30)` returns nothing while one is in flight, unless its lease is older than `lease_s`: then it returns the same command again. Claims for one bot are serialised.
- `recover_inflight(bot)` returns the in-flight command with a fresh lease, for a companion that restarts. It never claims a new one.
- Because the command keeps its epoch and cseq, a redelivery after a crash is answered by the bus from its stored reply and never runs twice.
- `command_progress(id, status, error, result)` allows only the moves in the diagram. Repeating the current status does nothing.

## Epochs

The bus refuses a cseq at or below its watermark unless the epoch is newer. If the hub ever loses its numbering (a reset, a restore), its next commands would all be refused. The companion therefore passes the epoch and cseq from each H frame to `sync_epoch`. When the bot is ahead of the hub, the hub:
- moves to a new epoch (`command_seq`, mirrored in `bots.epoch`);
- cancels queued commands of the old epoch;
- records an `epoch_changed` event.

## Tests

```sh
PGHOST=/tmp PGPORT=55433 PGUSER=postgres supabase/tests/run.sh
```

`run.sh` needs a PostgreSQL 15+ server and a superuser. It applies a small Supabase stand-in (`tests/00_platform_stub.sql`: API roles, `auth.uid()`, the publication, a fake pg_cron), then the migrations, then `tests/scenarios.sql`. The scenarios stop at the first failed check. They were checked against deliberate mutations of the migrations (lease, single flight, column grants, RLS, RPC caller checks, epoch handling), and each mutation made them fail.

## Rules for new migrations

- Enable row level security on every new table, revoke from `anon` and `authenticated`, and grant only what is needed, column by column where clients must not set a value.
- Revoke `execute` from `public` and `anon` on every new function. The scenarios check that no function in `public` is executable by either.
- SECURITY DEFINER functions set `search_path = ''` and check the caller themselves.
