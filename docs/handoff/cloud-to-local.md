# Handoff: from the cloud sessions to your PC

The first sessions, from 2026-09-26 to 2026-09-28, ran in Claude Code's cloud containers, with no game. This page is for the sessions that follow on your PC. It covers:
- where the work is and what is built;
- how to set up the PC;
- what those sessions learned the hard way.

The working rules are still in [CLAUDE.md](../../CLAUDE.md). The todo list, yours and Claude's, is "Next steps" in [plan.md](../plan.md#next-steps).

## Where the work is

- Everything is on the branch `claude/handoff-verification-plan-2ftwok`. `main` has only the initial README.
- CI is green on the branch's last code commit, `5cd4531` (run 20).
- The code depends on nothing that stayed in the cloud containers.

To get it:

```
git clone https://github.com/hopdad/Dual-universe.git
cd Dual-universe
git switch claude/handoff-verification-plan-2ftwok
```

Alternatively, merge the branch into `main` through a pull request and work from `main`.

## What is built

| Part | State | Details |
|---|---|---|
| Protocol v1 and the skills registry | Built | [protocol.md](../protocol.md), [packages/protocol](../../packages/protocol/) |
| Hub | Migrations `0001`–`0006`, the skills seed, 19 scenarios | [supabase/README.md](../../supabase/README.md) |
| Lua bus | Shim, adapter, builtins, collectors, job runtime and `goto`. Tested against a fake ArchHUD and the real ArchHUD code, never in game | [lua/README.md](../../lua/README.md) |
| Companion | Pump with lost-result recovery, router, Supabase client; `dufleet` `install`, `doctor`, `run`, `sim`, `cmd` and `decode` | [companion/README.md](../../companion/README.md) |
| Dashboard | Sign-in, fleet, bot and commands pages | [dashboard/README.md](../../dashboard/README.md) |
| Probe kit | Ready for the in-game session | [spikes/README.md](../../spikes/README.md) |

Not built yet:
- the transports, which wait for ADR-0001;
- the cargo collector and the watchdog;
- every skill after `goto`;
- the planner.

The "Done" notes under each workstream in the plan have the details.

## Setting up the PC

The in-game session needs only [uv](https://docs.astral.sh/uv/) (`winget install astral-sh.uv`), which fetches Python by itself. [spikes/README.md](../../spikes/README.md) has the rest.

For code work, the suites run here:

| Suite | Command | On Windows |
|---|---|---|
| Companion | `cd companion && uv run pytest && uv run ruff check .` | Natively. The tests that run the real Lua bus skip without `lua5.3` |
| Probe kit | `cd spikes/host && uv run pytest && uv run ruff check .` | Natively. The tests that need a Lua interpreter skip without one, and run with a Windows Lua 5.3 on `PATH` |
| Dashboard | `cd dashboard && npm ci && npm run lint && npm run typecheck && npm test` | Natively, with Node 22. The build and `npm run e2e` need the environment in [dashboard/README.md](../../dashboard/README.md) |
| Lua bus | `cd lua && ./tools/deps.sh && busted && luacheck .` | In WSL (Ubuntu 24.04), set up as below |
| Hub | `supabase/tests/run.sh` | In WSL with PostgreSQL 16, or leave it to CI. The script's header shows a throwaway cluster |

WSL, set up as in CI:

```
sudo apt-get install -y lua5.3 lua-busted lua-check lua-dkjson
sudo update-alternatives --set lua-interpreter /usr/bin/lua5.3
```

CI runs every suite on each push, so a push covers whatever the PC cannot run.

`.gitattributes` keeps LF line endings in Windows checkouts, so the shell scripts also work from Git Bash and from WSL. That holds for a fresh clone; a checkout made before that file existed keeps its old line endings until you re-clone.

## Lessons from these sessions

- CI cancels a run when a newer push to the same branch arrives. A cancelled run is not a failed one.
- Generated files:
  - After a change to `protocol.schema.json` or `skills.json`, run `python packages/protocol/codegen.py`.
  - Then, in `companion/`, run `uv run python ../packages/protocol/tools/make_vectors.py`.
  - CI checks both with `--check`.
- The dashboard build bakes in the `NEXT_PUBLIC_*` values. Without them every request fails, and Playwright times out waiting for the server.
- ArchHUD's `galaxyReference` cannot parse a `::pos` string. `atlasclass.lua:131` calls a global `stringmatch` that ArchHUD only declares as a local. The bus converts positions itself ([verification.md](../verification.md), ArchHUD addendum).
- `dufleet sim` runs the real Lua bus in the fake ArchHUD against a hub, which is the whole chain without the game. It needs `lua5.3`.
- The companion's PostgreSQL tests are opt-in locally: `DUFLEET_PG_TESTS=1` plus the usual `PG*` variables.

## Lessons from the first local session (2026-09-28)

- The offline tests passed and the probe still failed in game. The fake environment defined `system` and `unit` as globals, which files loaded with `require` never see in myDU. Test harnesses must hide the handler slots, as `spikes/lua/tests/test_probe.lua` now does.
- The game's `autoconf\custom\` files can belong to Administrators. Installing then needs Modify rights, granted once from an admin terminal; the installer now says so before it writes anything.
- With one monitor, screen capture needs the game in front. Retrying `optical locate` every few seconds until it finds the frame saves timing it by hand.
- Python holds back its output in background runs; set `PYTHONUNBUFFERED=1` to watch progress.
- In Git Bash, `grep` does not see carriage returns. Check line endings with `git ls-files --eol`, and keep scripts from writing CRLF.

## What a session on your PC can do

The cloud containers could not do these:
- Run the terminal half of the probe kit (`dufleet-probe paths`, `install`, `logwatch`, `inbox`, `optical`, `report`) while you play.
  - The in-game steps still need you.
  - So does `inject`, which types into the game window: run it yourself, with your hands off the keyboard and mouse.
- Put the bus in place with `dufleet install` and check it with `dufleet doctor`.

The rules stay the same. The only game files it writes are the ones listed under "Game files" in CLAUDE.md, and nothing reads or touches the client's memory.

## Starting the first local chat

Both prompts below were used on 2026-09-28. For what comes next, see "Next steps" in [plan.md](../plan.md#next-steps).

Before the in-game session:

> Read docs/handoff/cloud-to-local.md and "Next steps" in docs/plan.md, then help me get set up for the probe kit session.

After the session:

> Here are my probe kit results: summary.md, the panel's lines, the hello line, how the A1 trip went, and what the admins agreed to. Record them in docs/spikes.md and write ADR-0001.
