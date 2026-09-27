# Development plan

Built on [the handoff](handoff/original-handoff.md) as corrected by [verification.md](verification.md), plus the owner's decisions of 2026-09-26:

- client-only, no server mods ([ADR-0003](adr/0003-client-only-track.md));
- ArchHUD as the flight script, with the bot code running inside it ([ADR-0002](adr/0002-archhud-extension.md)).

Where these documents disagree with the handoff, they win.

## Decision gates

| Gate | Question | Status |
|---|---|---|
| D0 | Can a server mod run? | Decided: no. Client-only ([ADR-0003](adr/0003-client-only-track.md)) |
| D1 | Which flight script, and where does the bot code run? | Decided: inside ArchHUD's unit, through its `userclass.lua` hook ([ADR-0002](adr/0002-archhud-extension.md)). Confirm in A1, A2 and S10 |
| D2 | Telemetry out | Open: L (log tail) if S0 passes, otherwise O (optical frame drawn through `userScreen`) |
| D3 | Commands in | Open: F (a local file the bus re-reads) if S11 passes, otherwise C (chat keystrokes) |

ADR-0001 will record D2 and D3.

## What changes from the handoff

1. **Client-only.** Everything runs on the bot's own PC or VM. No server mods, no server-side APIs.
2. **ArchHUD instead of a Saga fork.** ArchHUD makes room for our code in three ways:
   - it loads its code from local files, so there is no paste-size limit;
   - it loads an optional extension file (`userclass.lua`) last, so the bus goes in without modifying ArchHUD;
   - it adds a `userScreen` string to its HUD, which gives the optical frame a slot.

   Its autopilot also flies standard ships and between planets, not only VTOL hops.
3. **Possibly no keystrokes for commands.** The game might let Lua re-`require` a local file after it changes (spike S11). If so, the companion writes commands into a small data file under `autoconf/custom/dufleet/`, and the bus polls it (Transport F). Keystroke injection would then be needed only for login and UI tasks. This spike is cheap and has the biggest payoff, so it runs early.
4. **Transport-independent work starts now:** the protocol, the hub schema, the dashboard, and the Lua and companion cores.
5. **The spec's artifacts are corrected** per the verification:
   - the schema fixes, plus a lease and recovery RPC;
   - `proxy.ts` instead of `middleware.ts`;
   - the protocol gaps (bounded split, command CRC scope, watermark dedupe with an epoch).

## Target architecture

```
          per bot: one Windows 10/11 host or VM running one myDU client
   ┌────────────────────────────────────────────────────────────────────┐
   │ myDU client                                                        │
   │   pilot seat or remote controller: ArchHUD 2.105 (pinned, as-is)   │
   │     └─ archhud/userclass.lua ─ requires ─ dufleet/ (our bot bus)   │
   │          dispatcher, skills, collectors, outbox, ArchHUD adapter   │
   │                                                                    │
   │ companion (Python)                                                 │
   │   out: log tailer (L) or HUD-frame reader (O)                      │
   │   in:  inbox file writer (F) or chat injector (C)                  │
   │   installer and doctor, launcher, login, watchdog                  │
   └─────────────────────────────────┬──────────────────────────────────┘
                                     │ device user, HTTPS and realtime
                              Supabase hub ◄──── dashboard (Next.js)
                                     ▲
                              planner (Python, Claude API)
```

Files on each bot host, all under the client's `Game/data/lua/autoconf/custom/`. The exact myDU path is confirmed in S8.

| Path | Owner |
|---|---|
| `ArchHUD.conf`, `archhud/` | The-Third-Verse/ArchHUD 2.105, modular master build, pinned to commit `6c95222`, unmodified |
| `atlas.lua` | The Third Verse's atlas (The-Third-Verse/AtlasFile, commit `48dd00f`). ArchHUD 2.105 loads it by default (`customAtlas = "atlas"`) |
| `archhud/userclass.lua` | Ours: a short shim that loads the bus |
| `dufleet/` | Ours: the bot bus |
| `dufleet/inbox.lua` | Written by the companion, only with Transport F |

## Phase 0: spikes

You run the in-game part. Claude prepares the probes under `spikes/` (a probe `userclass.lua` and host scripts) and writes the results into `docs/spikes.md` and ADR-0001. Run them in this order:

| ID | Question | Decides |
|---|---|---|
| S9 | Does the server admin permit client-side automation, including screen capture and keystroke or file-based commands? Get it in writing | go-live |
| S8 | Where does the myDU client keep `Game/data/lua` and its logs? Is EQU8 present? Can login be automated? CPU, RAM and GPU per client; FPS cap vs timer resolution | install, watchdog, sizing |
| A1 | Does the modular ArchHUD 2.105 build (The-Third-Verse master, not `BetaStandalone`) install from local files and fly on the target server? Check a pilot seat and a remote controller, a custom atlas if the server needs one, and an autopilot trip to a pasted `::pos` on the same planet and on another planet | D1 |
| A2 | Does the probe `userclass.lua` work? `ExtraOnStart` fires; the wrapped `PROGRAM.controlInput` sees `/b` lines before ArchHUD; a `dub` timer ticks through the wrapped `PROGRAM.onTick`; `userScreen` content shows | D1 |
| S11 | Are `package`, `package.loaded`, `load`, `loadfile` or `dofile` reachable? Does a re-`require` pick up a file the companion changed at runtime? How fast, and at what instruction cost? Prior: The Third Verse's AtlasFile README tells players to set `package.preload`, so the `package` table is reachable | D3 |
| S0 | Does `system.print` reach the disk log? Latency, maximum line length, escaping, file naming and rotation. Confirm `io` and `os` are absent. Prior: probably not | D2 |
| S1 | Is the 48×24 optical grid, drawn through `userScreen`, legible at the pinned resolution and HUD scale, and clear of ArchHUD's own elements? Decode error rate, instruction cost. If the HUD overlay is unreliable, the fallback is a screen unit; ArchHUD's `content/test-pattern*.svg` measure a screen's pixel accuracy | D2 |
| S3 | Chat open key, tab persistence, input length limit, behaviour with menus open. Needed for login and UI work even if S11 passes | injector |
| S4 | Unicode `SendInput` vs scan codes; an elevated client (UIPI); a locked or disconnected session; the idle check vs the companion's own input | injector |
| S10 | Instruction headroom of ArchHUD plus the bus over 2 h, parked and in flight (`getInstructionCount`/`getInstructionLimit`) | Phase 2 |
| S5 | Emitter ranges per size (`getRange`), the 512-character and one-per-frame limits, direct receiver links vs relays | Phase 3 |
| S6 | Worker boards: proximity radius, detection-zone restart, and confirmation that plug-started boards cannot print | Phase 3 |
| S7 | Confirm `MiningUnit` is read-only from Lua, and what calibration needs from the player | `mine_loop` |

Exit criteria:
- ADR-0001 is merged.
- Fixtures for the chosen transports are committed: a log sample or calibration PNGs, plus an inbox round trip or a chat transcript.
- `docs/spikes.md` records the measured limits, paths and keybinds.

## Phase 1: MVP on one client

Items marked *(ADR-0001)* wait for the transport decision. Everything else can start now.

### 1. Repository and CI

- The repository root is the monorepo root. Layout as in handoff §1, with these changes:
  - `lua/` holds plain Lua 5.3: the `dufleet/` modules and the `userclass.lua` shim. No DU-LuaC project is needed while everything loads from local files.
  - `spikes/` and `docs/adr/` are added.
  - There is no `mod/` directory.
- GitHub Actions jobs:
  - Lua 5.3 with busted, du-mocks and a fake-ArchHUD harness (stubs for `AP`, `ATLAS`, `PROGRAM` and the flags the adapter reads), plus luacheck.
  - Python with uv, ruff and pytest.
  - SQL against a PostgreSQL service, reusing the scenarios in `docs/verification/sql/`.
  - Web: Next.js build, lint and a Playwright smoke test.
- Done 2026-09-27: `.github/workflows/ci.yml` runs the Lua, Python (companion, protocol generators, probe kit) and SQL jobs. The web job comes with the dashboard.

### 2. Protocol (`packages/protocol`)

- JSON schemas for the outbound envelope and the command grammar.
- `vectors.json`, including:
  - the CRC check value `29B1`;
  - a body that contains `|`;
  - a multi-chunk base64 message;
  - command lines with CRCs.
- Codegen to Lua, Python and TypeScript constants.
- Close the handoff's gaps:
  - Split outbound lines at most 7 times.
  - The command CRC covers the UTF-8 bytes between `/b ` and ` #`.
  - One command in flight per bot.
  - Dedupe by watermark plus the persisted last reply, both scoped by a hub-issued epoch. The epoch travels in every command header (`/b <epoch>.<cseq> ...`), and all three live in one databank key, `dub.last`, written in a single call.
- Done 2026-09-27: [docs/protocol.md](protocol.md) specifies v1; `packages/protocol` holds the schema, the codegen for Lua and Python, and `vectors.json`. The TypeScript target comes with the dashboard.
- Positions in commands are written `pos=<systemId>,<bodyId>,<lat>,<lon>,<alt>`, never with the literal `::pos`. ArchHUD treats any chat line containing `::pos` as a new waypoint.
- *(ADR-0001, Transport F)* Inbox format: a Lua file that returns a data table (the epoch plus pending commands with their CRCs), written atomically as a temp file that is then renamed.

### 3. Hub (`supabase/`)

- Write fresh migrations with the fixes folded in, rather than the handoff files plus a patch:
  - RLS on every table, including `command_seq`.
  - `cseq` assigned by the server and immutable.
  - `claim_next_command` returns `setof`, allows one command in flight, and takes a lease (`claimed_at`, reclaimable after a timeout).
  - A `recover_inflight` RPC for companion restarts.
  - A `bot_report` RPC for device status.
  - Events are always owned.
  - `updated_at` triggers.
  - The realtime publication.
  - Retention through pg_cron.
- Run the verification scenarios in CI, as pgTAP or as the existing psql scenarios.
- Done 2026-09-27 ([supabase/README.md](../supabase/README.md)): migrations `0001`–`0005` with all of the above, plus column-level grants, `command_progress`, `cancel_command` and `sync_epoch` (a hub that lost its numbering moves to a new epoch instead of having every command refused). 16 psql scenarios in `supabase/tests/` run on plain PostgreSQL, and deliberate mutations of the migrations make them fail.

### 4. Lua bus (`lua/`)

- The `userclass.lua` shim:
  - loads the bus with `pcall(require, "autoconf/custom/dufleet/bus")`;
  - in `userBase.ExtraOnStart`, wraps `PROGRAM.controlInput` (handles `/b` lines and passes everything else to ArchHUD) and `PROGRAM.onTick` (handles the `dub` tag and passes the rest to ArchHUD), then calls `unit.setTimer("dub", 0.25)`;
  - in `userBase.ExtraOnStop`, persists state;
  - runs every entry point inside `pcall`, so a bus bug cannot break flight.
- Modules:
  - frame and outbox;
  - parser, which never throws and is fuzzed;
  - dispatcher, a single queue fed by `/b` chat lines, the inbox *(F)* and receivers (Phase 3);
  - dedupe;
  - builtins: `ping`, `status`, `cancel`, `pause`, `resume`, `setid`, `resend`, `db` and `cal` (there is no `epoch` verb: every command carries its epoch);
  - collectors: position and velocity from `construct`, autopilot state from ArchHUD's globals, run round-robin;
  - persistence: `dub.`-prefixed keys in ArchHUD's `dbHud_1`, which ArchHUD writes key by key and never clears;
  - `archhud_adapter`: the only module that touches ArchHUD internals.
- Transports *(ADR-0001)*: `print` (L) or `optical` through `userScreen` (O); `inbox` (F) or chat only (C).
- Done 2026-09-27 ([lua/README.md](../lua/README.md)): the shim, adapter, dispatcher, builtins, outbox, persistence, codec, and collectors for position, speed, altitude and autopilot mode, under busted and luacheck. Frames go out through `print` until ADR-0001. Still to come: fuel, cargo and body collectors, and the transports.

### 5. Companion (`companion/`, Python 3.12)

Core, which needs no ADR:
- Config: pydantic, `bots/*.toml`, passwords in keyring.
- `install` and `doctor`: put ArchHUD (the pinned commit) and the bus files in place and verify them by hash; report the client's Lua folder, log folder and window.
- Protocol constants from codegen, and the deframer.
- Hub client (supabase-py async):
  - device-user sign-in;
  - realtime on `commands` filtered by `bot_id`;
  - a poll on every (re)subscribe.
- Command pump: claim, deliver, wait for the ACK, retry at 1, 3 and 8 s, and recover in-flight commands on start.
- Telemetry sink: `bot_state` at 1 Hz, `telemetry` every 5 s.
- CLI: `run`, `install`, `doctor`, `replay`.

Transport adapters *(ADR-0001)*:
- Out: `ingest/log_tailer` (a `<record>` splitter with `stat()` polling) or `ingest/optical` with a `calibrate` command.
- In: the inbox writer (F), or `proc/window`, `inject/focus`, SendInput and chat (C). The injector is built either way, for login and UI tasks. Only C puts it on the command path.

### 6. Dashboard (`dashboard/`)

- Next.js 16 App Router, session refresh in `proxy.ts`, `@supabase/ssr` with the publishable key and `getClaims()`, Tailwind 4.
- Pages:
  - `/login` (magic link);
  - `/fleet`: realtime on `bot_state` and `bots`, with a version-drift badge;
  - `/bots/[id]`;
  - `/commands`: `ping` and `status` only.
- A Playwright smoke test: insert a `bot_state` row and check that the card updates.

### Acceptance

- A dashboard ping round-trips in under 5 s, 20 out of 20 times.
- Telemetry arrives at 1 Hz or better.
- Killing and restarting the companion mid-command still completes that command exactly once: no duplicate, nothing lost.
- Corrupt frames are rejected, and parser fuzzing never throws.
- The schema scenario suite is green in CI.
- With the bus loaded, ArchHUD still flies and handles its own chat commands normally (the A2 checklist).

## Phase 2: skills

### `goto`, through ArchHUD's autopilot

- Pre-checks:
  - ArchHUD has finished setting up (`SetupComplete`);
  - no autopilot mode is active;
  - fuel is above a threshold;
  - the target body is in ArchHUD's atlas (its custom atlas, on servers that change planets).
- Start: `ATLAS.AddNewLocation("dub-" .. job, worldPos, true)` selects the target, then a single `AP.ToggleAutopilot()` engages it. Never call it twice within 1.5 s: ArchHUD reads that as an orbital-hop request.
- Covers same-planet travel (vector to target with altitude hold, then landing), planet-to-planet flight (launch, orbit, reentry) and space targets.
- Arrival: within tolerance, under 1 km/h for 5 s, with all autopilot flags clear.
- Cancel: stop the autopilot and brake. The exact calls (`AP.ResetAutopilots`, `AP.BrakeToggle`) are fixed after A1.
- Anything running past twice its ETA is cancelled and re-planned.

### Other skills

- **`haul_route`:** `goto` legs, or ArchHUD routes (`AP.routeWP`), plus container volume checks. Itemised contents at most once per 30 s.
- **`industry`:** start, stop and maintain through the Industry API. `updateBank` at most once per 30 s. Large factories need several boards because of link slots.
- **`patrol`:** waypoints, dwell time, radar contacts.
- **`mine_loop`:** monitors mining units and schedules hauls. Calibration is a UI task (Phase 4 vision).

### Registry and map

- Rows in the `skills` table.
- `/map`, with bodies from the server's atlas (ArchHUD's `customAtlas` file where the server uses one).

### Acceptance

- 10 of 10 same-planet `goto` trips land within the radius set after A1. ArchHUD doesn't document its landing precision.
- 3 of 3 planet-to-planet trips arrive and park without intervention.
- 3 unattended haul loops.
- Cancel stops the autopilot and engages the brake within 2 s.
- A 2 h soak with no CPU overload.

## Phase 3: fleet and relay

- **Watchdog:** relaunch and re-login (S8), and resume the job from `dub.job`.
- **Deployment:** one companion per host, plus a version-drift alert. The `H` frame carries the bus version and the ArchHUD commit.
- **Relay, only if still needed:**
  - Worker boards are plug-started, so they cannot print or draw. They reply over their own emitter.
  - Worker boards load `dufleet/worker` from the same local files.
  - Messages are 512 characters or less, including framing, at most one per frame per channel.
  - The receiver links directly to the board.

Acceptance, unchanged from the handoff:
- 3 bots run for 8 h with at most 1 manual intervention.
- A killed client is back to `ready` in under 5 minutes.
- Relayed commands ACK 19 out of 20 times.

## Phase 4: planner and vision

- **Planner:** Python with the `anthropic` SDK 1.x.
  - The model ID comes from config. Set the default when Phase 4 starts, from the current Claude API model list, not from this document.
  - Tools are generated from the `skills` registry with strict schemas, which also fixes the `complete_goal`/`fail_goal` schema gaps.
  - Loop, memory and recovery as in handoff §7.
- **Vision:** Anthropic's computer-use toolset (`computer_toolset_20260801`).
  - The companion executes each action through `inject/focus`, with a region whitelist, a step cap, and an abort on any unexpected dialog.
  - It handles login, menus, market work and mining calibration.
  - Trades above a set value need confirmation on the dashboard.

Acceptance, unchanged from the handoff:
- A haul goal is completed with no human input.
- Injected failures end in the correct recovery or in `blocked`.
- Vision login succeeds 9 out of 10 times.

## Cross-cutting rules

- **Licensing:** ArchHUD is GPL-3.0 and the bus runs in its Lua VM. If the bus is ever distributed, license it GPL-3.0.
- **Security:**
  - Device users write only through RPCs.
  - The inbox file holds data only: a returned table, validated and CRC-checked. Only the bot's Windows account can write to its folder.
- **Windows hosts:**
  - The client and the companion run at the same integrity level, because UIPI blocks input into an elevated process.
  - The console session stays logged in and unlocked: use auto-logon, and never leave an RDP session disconnected.
  - The idle check ignores the companion's own injected input.
- **Local files:** the only game-folder files we write are `autoconf/custom/archhud/userclass.lua` and `autoconf/custom/dufleet/`, plus ArchHUD's own files at install time.

## Risks

| Risk | Mitigation |
|---|---|
| No log channel (likely) | Transport O, drawn through `userScreen` |
| No file inbox (S11 fails) | Chat keystrokes (Transport C), with focus checks after every send |
| Policy: NQ removed log output specifically to stop bots, and you are a player, not the admin | Written permission from the admin (S9) before any bot runs unattended |
| ArchHUD is dormant upstream, and the fork has one maintainer | Pin the commit; keep every ArchHUD call in `archhud_adapter`; run contract tests against the fake-ArchHUD harness; carry our own patches if needed (GPL-3.0 allows it) |
| ArchHUD plus the bus exceed the CPU quota | Timer-driven bus, round-robin collectors, the S10 soak; lower ArchHUD's HUD tick if needed |
| Focus contention during UI tasks | One client per VM, one input mutex, verification after every send |
| Client updates | Fixtures, plus `dufleet doctor` at startup |

## Open questions for you

Answered: the server is The Third Verse, which uses its own atlas (The-Third-Verse/AtlasFile). The dashboard map will read the same file.

1. Supabase: a new hosted project, an existing one, or self-hosted?
2. Fleet size and hosts: spare PCs, Hyper-V GPU-P VMs, or cloud instances?
3. The `Ai helper/` folder: keep it, remove it, or give it a purpose?

## Next steps

1. **You:** get the admin's written permission (S9).
2. **You:** run the probe kit, following [spikes/README.md](../spikes/README.md). It covers S8, A1, A2, S0, S11, S1, S3, S4 and S10 in one session. At the end, paste back `results/summary.md` and the panel's lines.
3. **Claude:** write ADR-0001 from the results. In parallel, start Phase 1 workstreams 1–3 and the transport-independent parts of 4–6.
