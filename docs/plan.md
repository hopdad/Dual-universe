# Development plan

Built on [the handoff](handoff/original-handoff.md) as corrected by [verification.md](verification.md). Where they disagree, this plan and the verification report win.

## What changes from the handoff

1. **A server-access gate comes first.** myDU has a native Lua-to-server call (`system.modAction`). Server mods can also push JavaScript to a client that raises Lua events there (`CPPMod.luaElementEmitEvent`). Where a mod can be installed, that replaces the log tail, the optical frame and the keystroke injector. The plan therefore has two transport tracks:
   - Track M (mod-assisted), used where a mod can be installed.
   - Track C (client-only), the handoff's design.
2. **The bus runs beside Saga, not inside it.** Saga's release build uses 99% of the 200,000-byte paste limit and owns the HUD. The preferred topology is a sidecar programming board next to an unmodified Saga. A trimmed Saga fork is the fallback if spike S2 fails.
3. **Transport-independent work starts now.** The protocol, the hub schema, the dashboard, and the Lua and companion cores don't depend on the spikes. Only the transport adapters wait for the ADRs. (The handoff blocked all of Phase 1 on S0.)
4. **The spec's artifacts are corrected:**
   - the `project.json` format;
   - the schema, with the `0005_fixes.sql` changes plus a lease and recovery RPC;
   - `proxy.ts` instead of `middleware.ts`;
   - the protocol gaps (bounded split, chat CRC scope, watermark dedupe with an epoch).
5. **Later phases are re-scoped:**
   - The `goto` acceptance depends on flight mode.
   - `mine_loop` monitors and hauls; calibration is a UI task.
   - Plug-started worker boards report over emitters only.
   - The vision loop uses Anthropic's computer-use toolset.
   - On track M, market work moves server-side.

## Decision gates

| Gate | Question | Decided by | Options (preferred first) |
|---|---|---|---|
| D0 | Can a DLL mod run on the target server(s)? | You: server admin, or the admin's written consent | M (mod-assisted) or C (client-only). Both may apply on different servers |
| D1 | Where does the bot bus run? | S2, S1b, S10 | Sidecar PB beside unmodified Saga, or trimmed Saga fork |
| D2 | Telemetry out | D0, then M1 or S0/S1 | M (`system.modAction`), then L (log tail), then O (optical HUD frame) |
| D3 | Commands in | D0, then M2 or S3/S4 | M (mod-raised Lua event), then C (chat keystrokes) |

Each gate ends in an ADR: ADR-0001 transport (D2, D3), ADR-0002 Lua topology (D1), ADR-0003 server track (D0).

## Target architecture

```
        per bot: one Windows 10/11 host or VM running one myDU client
   ┌──────────────────────────────────────────────────────────────────┐
   │  pilot seat ── Saga (upstream build, untouched, GPL-3.0)         │
   │  bus PB ────── ours: dispatcher, skills, collectors, outbox       │
   │  companion ─── launcher, login, watchdog                         │
   │                track C adds: chat injector, log or HUD ingest    │
   └──────────┬───────────────────────────────────────┬───────────────┘
   track M:   │ system.modAction  ↑                    │ track C:
              │ luaElementEmitEvent ↓                  │ log tail or HUD frame ↑
   ┌──────────┴──────────────┐                         │ chat keystrokes ↓
   │ myDU server + ModDuFleet │                         │
   └──────────┬──────────────┘                         │
              └──────────────►  Supabase hub  ◄────────┘
                                  ▲       ▲
                           dashboard     planner (Claude API)
```

Both tracks share the protocol, the Lua bus core, the hub, the dashboard and the planner. Only the adapters at the two ends differ.

## Phase 0: spikes and gates

You run the in-game part. Claude prepares the probe builds and host scripts under `spikes/` and writes up the results in `docs/spikes.md` and the ADRs.

| ID | Track | Question | Decides |
|---|---|---|---|
| S0 | C | Does `system.print` reach the disk log? Measure latency, maximum line length, escaping, file naming and rotation, in `%LOCALAPPDATA%\NQ\DualUniverse\log\` and wherever the myDU client writes. Confirm `io` and `os` are absent. Prior: likely no, since NQ removed log output to stop bots | D2 |
| S1 | C | Is the 48×24 optical grid legible at the pinned resolution and HUD scale? Redraw rate, decode error rate, instruction cost | D2 |
| S1b | C | Does a sidecar PB's `setScreen` layer show while the avatar sits in Saga's seat, which redraws its own HUD every frame? | D1, D2 |
| S2 | both | Activate the bus PB (F), then sit in Saga's seat. Does the PB keep running, keep printing, and still receive `onInputText`? Do Saga's own commands still work? Does chat reach every running unit? | D1 |
| S3 | C | Chat open key, tab persistence, input length limit, behaviour when a menu is open | injector |
| S4 | C | Unicode `SendInput` vs scan codes. Does an elevated client block input (UIPI)? What happens when the session is locked or disconnected? Does the idle check ignore the companion's own input? | injector |
| S5 | both | `getRange()` per emitter and receiver size. Confirm the 512-character and one-per-frame limits. Receiver linked directly to the PB vs through relays | Phase 3 |
| S6 | both | PB proximity radius, detection-zone restart. Confirm that plug-started boards cannot print | Phase 3 |
| S7 | both | Confirm `MiningUnit` is read-only from Lua, and what calibration needs from the player | `mine_loop` |
| S8 | both | Login automation; whether EQU8 ships with the myDU client; client install and log paths; per-client CPU, RAM and GPU; FPS cap vs timer resolution | watchdog, sizing |
| S9 | both | The admin's written policy on automation, screen capture and mods | go-live |
| S10 | both | Instruction headroom of Saga plus the bus over 2 h (`getInstructionCount`/`getInstructionLimit`) | D1, Phase 2 |
| M1 | M | `system.modAction`: maximum payload, rate limit, latency. Test from a seat, from an explicitly run PB and from a plug-started PB | D2, Phase 3 |
| M2 | M | `luaElementEmitEvent`: which slot and event pairs reach the bus PB (receiver `onReceived`, `system` `onInputText`, a custom event) and Saga's seat | D3, Phase 2 |
| M3 | M | Hub bridge: the mod posts to Supabase over HTTPS, or writes NDJSON that a sidecar process forwards. Where the hub credential lives | architecture |

Exit criteria:
- ADR-0001, ADR-0002 and ADR-0003 are merged.
- A fixture is committed for the chosen transport: log sample, optical calibration PNGs, or `modAction` payloads.
- `docs/spikes.md` records the measured limits and keybinds.

## Phase 1: MVP on one client

Items marked *(ADR)* wait for the gate. Everything else can start now.

### 1. Repository and CI

- The repository root is the monorepo root. Layout as in handoff §1, plus:
  - `mod/` (track M only);
  - `spikes/`;
  - `docs/verification/` (already present).
- GitHub Actions jobs:
  - Lua 5.3 with busted and du-mocks.
  - A DU-LuaC 1.3.5 build that reports every build's size and fails above 90% of the 200,000-byte JSON limit.
  - Python with uv, ruff and pytest.
  - SQL against a PostgreSQL service, reusing the scenario tests from `docs/verification/sql/`.
  - Web: Next.js build, lint and a Playwright smoke test.

### 2. Protocol (`packages/protocol`)

- JSON schemas for the outbound envelope and the chat grammar.
- `vectors.json`, including:
  - the CRC check value `29B1`;
  - a body that contains `|`;
  - a multi-chunk base64 message;
  - chat lines with CRCs.
- Codegen to Lua, Python and TypeScript constants.
- Close the handoff's gaps:
  - Split outbound lines at most 7 times.
  - The chat CRC covers the UTF-8 bytes between `/b ` and ` #`.
  - One command in flight per bot.
  - Dedupe by watermark (`dub.cseq_last`) plus the persisted last ACK, both scoped by a hub-issued `epoch` (`dub.epoch`), so that resetting the hub doesn't turn every new command into a "duplicate".

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

### 4. Lua bus (`lua/`, DU-LuaC format 5)

- Build `bus` for the sidecar PB. Slots: `core`, `db` (databank), and optionally `screen` and `emit`.
- Modules:
  - frame and outbox;
  - parser, which never throws and is fuzzed;
  - dispatcher, a single queue fed by `onInputText`, receiver `onReceived`, and track-M emitted events;
  - dedupe;
  - builtins: `ping`, `status`, `setid`, `cal`, `resend`, `epoch`;
  - collectors: position and speed from `construct`, cargo from `getItemsVolume`, run round-robin;
  - persistence under `dub.` keys on the bus's own databank.
- Transport adapters behind `---@if transport` *(ADR)*: `modaction`, `print`, `optical`.
- busted specs with a fake clock, a stub `system.modAction`, and an instruction-budget regression test.

### 5. Companion (`companion/`, Python 3.12)

Core, which needs no ADR:
- Config: pydantic, `bots/*.toml`, passwords in keyring.
- Protocol constants from codegen, and the deframer.
- Hub client (supabase-py async):
  - device-user sign-in;
  - realtime on `commands` filtered by `bot_id`;
  - a poll on every (re)subscribe.
- Command pump: claim, deliver, wait for the ACK, retry at 1, 3 and 8 s, and recover in-flight commands on start.
- Telemetry sink: `bot_state` at 1 Hz, `telemetry` every 5 s.
- CLI: `run`, `replay`, `doctor`.

Track C *(ADR)*:
- `proc/window`.
- Injection: `inject/focus`, SendInput and chat.
- `ingest/log_tailer`: DU-LogFramework-style `<record>` splitter with `stat()` polling.
- And/or the optical reader, with a `calibrate` command.

Track M *(ADR)*:
- `mod/ModDuFleet`, a C# net6.0 DLL mod:
  - `TriggerAction` receives bus frames;
  - commands are pushed through IPub, `modinjectjs` and `luaElementEmitEvent`;
  - the hub bridge follows M3.
- The companion shrinks to launcher, login and watchdog.

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

## Phase 2: skills

### `goto`

Mode-aware:
- Check links and flight mode first. Maneuver mode needs a VTOL-capable construct.
- Sidecar topology: Saga's own `/goto ::pos{}` reaches Saga's unit through the command path.
  - Track C: the companion types it.
  - Track M: an emitted `onInputText` on Saga's unit if M2 allows it; otherwise the companion types it.
- Fork topology: an in-process adapter calls `convertToWorldCoordinates`, `AutoPilot:setTarget`, `gotoTarget` and `onAlt1`.
- Arrival: within tolerance and under 1 km/h for 5 s.
- Cancel: brake, matching Saga's CTRL behaviour.
- Anything running past twice its ETA is aborted and re-planned.

### Other skills

- **`industry`:** start, stop and maintain through the Industry API. `updateBank` at most once per 30 s. Large factories need several boards because of link slots.
- **`haul_route`:** `goto` legs plus container volume checks. Itemised contents at most once per 30 s.
- **`patrol`:** waypoints, dwell time, radar contacts.
- **`mine_loop`:** re-scoped. It monitors mining units (state, pools, calibration rate) and schedules hauls. Calibration is a UI task (Phase 4 vision), or a server-side action on track M.

### Registry and map

- Rows in the `skills` table.
- `/map`, with bodies seeded from DU-OpenData or Saga's atlas and checked per server.

### Acceptance

- Maneuver mode on a VTOL construct: 10 of 10 same-planet trips land within 5 m.
- Standard mode: 10 of 10 arrivals within the radius set in the Phase 2 ADR.
- 3 unattended haul loops.
- Cancel engages the brake within 2 s.
- A 2 h soak with no CPU overload on either unit.

## Phase 3: fleet and relay

- **Watchdog:** relaunch and re-login (S8), and resume the job from `dub.job`.
- **Deployment:** one companion per host, plus a version-drift alert.
- **Relay, only if still needed:**
  - Worker PBs are plug-started, so they cannot print or draw. They reply over their own emitter.
  - Messages are 512 characters or less, including framing, at most one per frame per channel.
  - The receiver links directly to the PB.
  - On track M, if M1 shows that plug-started boards can call `system.modAction`, workers report directly and the relay carries commands only.

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
  - Trades above a set value need confirmation on the dashboard.
- **Track M:** market and industry reads and orders run server-side through the gameplay API, following the TraderBot sample. Vision is left for login and menus.

Acceptance, unchanged from the handoff:
- A haul goal is completed with no human input.
- Injected failures end in the correct recovery or in `blocked`.
- Vision login succeeds 9 out of 10 times.

## Cross-cutting rules

- **Licensing:**
  - The sidecar keeps our Lua separate from Saga, which stays GPL-3.0 on its own unit.
  - A trimmed fork makes the combined build GPL-3.0.
  - du-tools is GPL-3.0: read it, but don't copy it into non-GPL code.
- **Security:**
  - Device users write only through RPCs.
  - The mod has unrestricted server access, so it gets a narrowly scoped hub identity and a review before it's deployed.
  - Hub secrets never go into Lua.
- **Windows hosts (track C):**
  - The client and the companion run at the same integrity level, because UIPI blocks input into an elevated process.
  - The console session stays logged in and unlocked: use auto-logon, and never leave an RDP session disconnected.
  - The idle check ignores the companion's own injected input.
- **Size gate:** CI reports every Lua build's size and fails above 90% of the JSON paste limit.

## Risks

| Risk | Mitigation |
|---|---|
| No log channel on track C (likely) | Transport O is built in; track M avoids the question |
| Policy: NQ removed log output specifically to stop bots | Written consent per server (S9). Track M needs the admin anyway |
| The sidecar can't run beside Saga's seat (S2 fails) | Trimmed Saga fork with an in-process adapter, at a maintenance cost |
| `luaElementEmitEvent` can't raise the needed events (M2) | Commands fall back to chat keystrokes; telemetry can stay on `modAction` |
| The mod API changes between myDU server versions | Record the server version in ADR-0003; keep M1 and M2 as regression checks |
| Focus contention (track C) | One client per VM, one input mutex, verification after every send |
| CPU overload | Timers, round-robin collectors, the S10 soak; the sidecar splits load across units |
| Client updates | Fixtures plus `dufleet doctor` at startup |

## Open questions for you

1. **D0:** do you run the target myDU server(s), or can their admins install a DLL mod? This is the biggest fork in the plan.
2. Which constructs will the bots fly? VTOL-capable ones (Saga's Maneuver mode) or standard autopilot ships? Same planet only at first?
3. Supabase: a new hosted project, an existing one, or self-hosted?
4. Fleet size and hosts: spare PCs, Hyper-V GPU-P VMs, or cloud instances?
5. The `Ai helper/` folder: keep it, remove it, or give it a purpose?

## Next steps

1. **You:** answer questions 1 and 2.
2. **Claude:** build the Phase 0 kit in `spikes/`:
   - DU-LuaC probe builds for S0, S1, S1b, S2, S5 and S10;
   - host scripts for log grep, dxcam capture and a SendInput test;
   - if track M is possible, a minimal logging mod for M1 and M2.
3. **You:** run the probes in game and paste the results. The handoff estimates S0 at 15 minutes; the full set is a few hours.
4. **Claude:** write ADR-0001 to ADR-0003. In parallel, start Phase 1 workstreams 1–3 and the transport-independent parts of 4–6.
