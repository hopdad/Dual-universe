# Handoff verification

Checked on 2026-09-26 against [the handoff](handoff/original-handoff.md). Where the two disagree, this report wins. [plan.md](plan.md) is built on it.

> Update, same day: the project owner chose the client-only track ([ADR-0003](adr/0003-client-only-track.md)) and ArchHUD as the flight script ([ADR-0002](adr/0002-archhud-extension.md)). ArchHUD was verified in the [addendum](#addendum-archhud). The Saga findings below are still true, but they no longer drive the plan. Finding 1 (server mods) is out of scope for now.

## How it was checked

| Area | Method |
|---|---|
| Lua API | Grep of the EmmyLua Codex that DU-LuaC generates from Novaquark's official API mockup (the last official 1.x API) |
| Referenced projects | Read from shallow clones (table below) |
| SQL (handoff §5) | Migrations 0001–0003 applied to PostgreSQL 16.13 with a small Supabase stand-in, then scenario tests as owner, other tenant, device user and `anon`: [verification/sql/](verification/sql/) |
| DU-LuaC (handoff §3) | Builds with DU-LuaC 1.3.5, the current npm release, of the handoff's `project.json`, a corrected one, and Saga: [verification/luac/](verification/luac/) |
| Protocol (handoff §2) | CRC-16/CCITT-FALSE check value and optical-frame arithmetic, in Python |
| Stack | npm and PyPI registries, current vendor docs |

| Repository | Commit | Date |
|---|---|---|
| tobitege/du-saga | a3c2356 | 2025-09-01 |
| tobitege/du-tools | fcd540e | 2026-08-09 |
| dual-universe/mydu-server-mods | 2976642 | 2026-04-27 |
| wolfe-labs/DU-LuaC | abe06c4 (npm 1.3.5) | 2024-05-02 |
| 1337joe/du-mocks | a510c77 | 2024-09-27 |
| PerMalmberg/du-yfs | 6561e1b | 2024-01-13 |
| wolfe-labs/DU-LogFramework | 89b09d1 | 2021-12-21 |
| Dimencia/DU-Audio-Sharp | a878c0c | 2022-02-08 |
| tiramon/du-map-companion | d9d6970 | 2022-10-15 |

The verification environment could not reach `support.dualthegame.com` or `installer-prod.dualthegame.com` (blocked by its egress proxy). Claims that rest only on those sites stay open.

## Verdict

The architecture holds: commands in, a transport-agnostic protocol out, a Supabase hub, a dashboard, and a planner that only composes vetted skills. Eight findings change how it gets built.

### 1. myDU already has a Lua-to-server channel (new; changes the transport decision)

- Lua can call `system.modAction(modName, actionId, constructId, elementId, playerId, payload)`. A server DLL mod receives it in `TriggerAction`.
  - Novaquark's own sample calls it from a control seat (`mydu-server-mods/ModRotateEngine/Readme.md:39`).
  - du-tools' ModFlightLogger streams flight telemetry this way (`du-tools/ModFlightLogger/README.md:97`).
- The reverse direction exists too. A mod can push JavaScript to one player's client through the `modinjectjs` event, which `eval()`s its payload (toolkit doc, line 47). That JavaScript can call `CPPMod.luaElementEmitEvent(constructId, elementId, slotName, eventName, [args])`, which "Emit[s] an event as if the unit had received it" (`APIReference/JavascriptAPI.md:94`).
- The toolkit can log in headless "Bot" users (`CreateUser`) and ships a `TraderBot` that places market orders server-side.
- du-tools, by Saga's maintainer and active in August 2026, already runs an MCP bridge on this mechanism (DuMcpBridge plus ModUiToolbox).
- `system.modAction` is a myDU addition. It is not in the 1.x Codex or in du-mocks.

Consequence: on any server where the admin installs a small mod, telemetry out and commands in need no log tail, no OCR and no keystroke injection. The handoff calls this path out of scope. The plan makes it decision gate D0.

### 2. The bot bus does not fit inside Saga (wrong)

- DU-LuaC checks every build against 200,000 bytes for a JSON paste and 180,000 bytes for CONF (`src/commands/BuildProjectCommand.ts:169,184`).
- Saga's release build is 198,055 bytes as JSON (99.0%, 1,945 bytes left) and 197,430 bytes as CONF, which is already over that limit. Rebuilding it here produced a byte-identical file.
- DU-LuaC's `compress` build option makes it bigger (198,805 bytes).
- Saga's README already says features were removed "to make room for new code".

Consequence: "fork Saga and put the bus inside it" only works if Saga features are deleted. The plan prefers a sidecar programming board next to an unmodified Saga, gated on spike S2, with a trimmed fork as the fallback.

### 3. Saga owns the control unit's HUD (wrong for Transport O)

`HUD.update()` builds the whole HUD into one string and calls `system.setScreen(rendered)` (`lua/hud/hud.lua:151`). It runs from `onUpdate` on every frame (`lua/events/system_update.lua:46`). An optical frame drawn with `setScreen` from the same unit would be overwritten on the next frame. The frame has to be composited into Saga's string (fork) or drawn by another unit (spike S1b).

### 4. Units started by a plug signal cannot print or draw (missed)

The Codex marks `system.print`, `setScreen`, `showScreen` and the widget calls as "disabled if the player is not running the script explicitly (pressing F on the Control Unit, vs. via a plug signal)". `getWaypointFromPlayerPos` and `setWaypoint` are "only in explicit runs". Worker PBs restarted by a detection zone or a receiver can only report over an emitter. Whether `system.modAction` has the same restriction is spike M1.

### 5. The `project.json` in §3 does not build (wrong)

DU-LuaC 1.3.5 stops at the first slot: `Can't initialize a Slot without a name! Data: {"type":"CoreUnit"}`.

- Each slot needs a `name` and a `type`. The `type` is a DU-LuaC key (`core`, `databank`, `telemeter`, `emitter`, `receiver`, `screen`), not an element class.
- The entry file is named after the build (`src/pilot.lua`, `src/worker.lua`), not `src/main.lua`.
- `fmtVersion` 5 is the current format. DU-LuaC 1.3.5 writes it for new projects and Saga uses it; v2 still loads.
- Targets should set `handleErrors` (on in development, off in production).
- The in-game databank class, for `getLinksByClass`, is `DataBankUnit`, not `DatabankUnit`.

The [corrected file](verification/luac/corrected/project.json) builds, and `---@if transport "optical"` compiles exactly one branch into each target.

### 6. The schema has seven defects, three of them security holes (wrong)

All four files apply cleanly. The scenario tests then showed:

| # | Defect | Effect |
|---|---|---|
| 1 | `command_seq` has no RLS | Any tenant, and `anon` without logging in, can read and reset any bot's sequence. The owner's next command then fails with a duplicate key |
| 2 | `bots_device_update` has no column limits | The device user can set `owner_id` to itself and lock the owner out. This contradicts "a compromised VM can only touch its own bot" |
| 3 | `events` rows with `bot_id is null` | Every tenant can read and delete them |
| 4 | Clients may supply `cseq` | The trigger only fires `when (new.cseq is null)`, so a client can jump the sequence (tested with 999) |
| 5 | `claim_next_command` returns a composite | An empty queue returns one all-NULL row instead of no rows |
| 6 | No single-flight in the database | A second claim hands out cseq 2 while cseq 1 is still un-acked |
| 7 | No recovery for `claimed` or `sent` rows | After a companion crash those rows are never re-driven, so a command can be lost |
| – | Minor | The goals foreign key blocks bot deletion; `updated_at` is never set; `skills_read` uses the legacy `auth.role()` form |

[0005_fixes.sql](verification/sql/0005_fixes.sql) closes 1–6, the goals foreign key and the `skills_read` policy (`updated_at` only for `commands`), and the same scenarios then show the safe outcome ([results below](#schema-test-results)). Defect 7 needs a lease and recovery RPC, which is in Phase 1 of the plan.

### 7. Saga's `/goto` behaves differently per flight mode (partly wrong)

- In Standard mode, `/goto ::pos{}` sets the autopilot target and switches the autopilot on (`lua/events/system_input.lua:176-205`, then `onAlt1` in `lua/events/keyboard.lua:47`).
- Only in Maneuver mode does it climb, align, traverse and land automatically. Saga restricts Maneuver mode to VTOL-capable constructs and warns against using it for interplanetary trips.
- Aborting is a tap on the brake key (CTRL), which brings a VTOL ship to a stop. The handoff's "cancel cuts thrust" has no direct equivalent.

The Phase 2 target "lands within 5 m, 10 of 10" matches Maneuver mode's documented precision landing. Standard-mode autopilot precision is not documented, so the plan gives it a separate acceptance radius.

### 8. The dashboard stack moved (wrong)

- Next.js is at 16.3. Since 16, `middleware.ts` is deprecated in favour of `proxy.ts`, which runs on Node.
- Current Supabase SSR guidance: use the publishable key, `getAll`/`setAll` cookie handlers, and `getClaims()` to protect pages.

## Claim by claim

Status: CONFIRMED, PARTLY (true with a caveat), WRONG, GAP (the spec leaves it undefined), OPEN (not verifiable here, moved to a spike).

### The handoff's Key Findings table

| Topic | Status | Evidence or correction |
|---|---|---|
| Lua log writing removed (Panacea) | CONFIRMED | MassivelyOP summary (2022-01-18). The Codex has no `System.log*`. The only similar call is `RenderScript.logMessage`, which writes to the Lua channel when the screen's "enable output in Lua channel" box is ticked |
| Log-based tools deprecated | CONFIRMED | DU-Audio-Sharp README:3; du-map-companion README:66. The ZarTaen quote was not checked |
| NQ stripped log data | CONFIRMED | du-map-companion README:66 |
| Log location | PARTLY | `%LOCALAPPDATA%\NQ\DualUniverse\` per NQ support (search result). DU-LogFramework adds: subfolder `log\`, newest file sorts last, entries are `<record>` elements with `<logger>` and `<message>` children (`index.js:38-55,109-114`). The myDU client installs to `C:\ProgramData\My Dual Universe` (ClientModManager README:13); its log folder is unconfirmed (S0, S8) |
| Log encoding | OPEN | Release note not re-read. Keeping `errors="replace"` costs nothing |
| Forum reaction (QR codes plus OCR) | OPEN | Forum not fetched. "Wolfram" is Matt of Wolfe Labs, the DU-LuaC author (Saga README:369) |
| Saga chat commands | PARTLY | All listed commands exist; `/goto` depends on flight mode (finding 7) |
| Saga maintenance | CONFIRMED | 4.1.6.2 of 2025-09-01, GPL-3.0, DU-LuaC, GFN note. Default-branch HEAD is 2025-09-01; "updated Apr 2026" was not seen |
| Saga constraints | CONFIRMED | All quotes match (README:39, 41, 144, 343-344). It is also at 99% of the paste limit (finding 2) and owns the HUD (finding 3) |
| YFS | CONFIRMED | README:4; link order README:75-77. Reference only |
| DU-LuaC features | CONFIRMED | `onEvent`, `getLinksByClass`, `embedFile` and `---@if` all build |
| DU-LuaC project format | WRONG | Format 5 is current and the example does not build (finding 5) |
| Emitter/receiver relay quirk | OPEN | Forum not fetched. The Codex adds hard limits ([below](#api-limits-the-handoff-did-not-have)) |
| du-mocks | CONFIRMED | README:6, 30, 53; last commit 2024-09-27. Needs Lua 5.3 or later (rockspec). Has no `system.modAction` |
| Windows 10/11 and AVX | OPEN | NQ support blocked here; nothing contradicts it |
| EQU8 exception for `Game/data/lua` | OPEN | NQ support blocked here. The myDU client's install path differs from the official client's |
| myDU server mods | CONFIRMED, understated | Quote at toolkit doc line 67. This is a first-class transport, not only "the clean path if an admin cooperates" (finding 1) |
| du-tools | CONFIRMED, understated | README now read: an MCP bridge, a JavaScript-injection toolbox, and a Lua telemetry mod |

### Other claims in the spec

| Claim | Status | Note |
|---|---|---|
| `onInputText` exists | CONFIRMED | Codex: "A new message has been entered in the Lua tab of the chat, acting like a command line interface" |
| A `/b` handler can coexist with Saga | CONFIRMED | Saga registers through DU-LuaC's multi-handler (`lua/saga.lua:192`) and silently ignores commands it does not know |
| An in-process `SagaAdapter` is possible | CONFIRMED, same unit only | The `/goto` path uses globals: `convertToWorldCoordinates`, `AutoPilot:setTarget`, `resetAP`, `gotoTarget`, `onAlt1` |
| Industry skill from Lua | CONFIRMED | `startRun`, `startMaintain`, `startFor`, `stop`, `getState`, `getInfo`. The class `IndustryUnit` matches DU-LuaC |
| `mine_loop` waits for S7 | MOSTLY ANSWERED | `MiningUnit` has only getters (state, ore pools, rates, last extraction) and no calibrate or start call, so calibration has to happen outside Lua (the player's UI, or a server mod) |
| CPU quota | CONFIRMED (API only) | `system.getInstructionCount()` and `getInstructionLimit()` exist; the numbers still need measuring |
| `unit.setTimer('bot', 0.25)` | CONFIRMED | Timer resolution is bounded by the framerate, so a low FPS cap also slows ticks and the optical frame rate |
| `setScreen` for Transport O | PARTLY | Exists, but conflicts with Saga (finding 3) and works in explicit runs only |
| Optical frame capacity | CONFIRMED | 48×24 cells × 2 bits = 288 bytes; minus a 16-byte header and a 2-byte CRC leaves 270 bytes; 540–1,080 B/s at 2–4 fps. The sample 130-byte telemetry body fits one frame |
| CRC-16/CCITT-FALSE | CONFIRMED | check("123456789") = `29B1`, empty input = `FFFF` |
| Outbound line parsing | GAP | JSON bodies can contain `\|`, so a parser must split at most 7 times |
| Chat CRC | GAP | The covered bytes are not defined. Proposal: the UTF-8 bytes between `/b ` and ` #` |
| Dedupe (ring of 64 plus saved last cseq) | GAP | After a PB restart only the saved watermark survives. With in-order, single-flight delivery, a watermark plus the persisted last ACK is enough. An epoch is also needed, or a hub reset makes every new command look like a duplicate |
| Realtime (telemetry not published) | CONFIRMED | Sound. supabase-py's async client supports `on_postgres_changes` with a `filter` |
| Companion as device user, never service role | PARTLY | The right idea, but RLS as written lets the device user take ownership (finding 6) |
| Planner tool schema | GAP | `complete_goal` and `fail_goal` list `required` keys with no `properties`; the skill enum is hard-coded and should come from the `skills` table |
| Vision loop | UPDATE | Anthropic's computer-use toolset (`computer_toolset_20260801`, GA on the Claude API) is built for screenshot-then-click loops. Execute its actions through `inject/focus` instead of inventing an action protocol |

## API limits the handoff did not have

From the Codex. Spikes should confirm these, not rediscover them.

| API | Limit |
|---|---|
| `Emitter.send(channel, message)` | One transmission per frame per channel. A channel over 64 characters is not sent. Messages are truncated at 512 characters |
| `Emitter.getRange()`, `Receiver.getRange()` | The range can be read in game (S5) |
| `Container.updateContent()` | One call per 30 s. `getItemsVolume()` and `getMaxVolume()` need no refresh |
| `Industry.updateBank()` | One call per 30 s |
| `unit.setTimer(tag, period)` | Resolution limited by the framerate |
| `system.print`, `setScreen`, `showScreen`, widgets | Explicit runs only |
| `system.playSound(path)` | Plays a file from the user's audio folder; the post-Panacea replacement for log-based audio tools |
| `Telemeter.getMaxDistance()` | 100 m by default |

## Schema test results

Run by [sql/run.sh](verification/sql/run.sh). "Handoff" is migrations 0001–0003 as written; "Fixed" adds [0005_fixes.sql](verification/sql/0005_fixes.sql).

| Scenario | Handoff | Fixed |
|---|---|---|
| Server assigns cseq 1, 2, 3 | 1,2,3 | 1,2 (two inserted) |
| Second claim while cseq 1 is un-acked | Hands out cseq 2 | 0 rows |
| Claim on an empty queue | 1 row, all NULL | 0 rows |
| Other tenant reads or resets `command_seq` | Sees 1 row, resets 1 row | Permission denied |
| `anon` reads `command_seq` | Sees 1 row | Permission denied |
| Owner inserts after the reset | Duplicate key error | n/a |
| Other tenant reads or deletes null-bot events | Sees 1, deletes 1 | Sees 0 |
| Device user sets `bots.owner_id` to itself | 1 row updated; owner sees 0 bots | 0 rows; status goes through the `bot_report` RPC |
| Client inserts cseq 999 | Accepted | Ignored (gets 3) |
| Client rewrites `verb` after insert | Accepted | Rejected as immutable |
| Delete a bot that a goal references | Foreign key error | Goal kept with `bot_id` null |

`0004_retention.sql` was not executed because pg_cron is not in plain PostgreSQL. Check it with `supabase start`.

## Build results

| Build | Result |
|---|---|
| Handoff `project.json` | `[ERROR] Can't initialize a Slot without a name! Data: {"type":"CoreUnit"}` |
| Corrected `project.json` (pilot and worker, two targets) | Success, 9–10 kB JSON each. Development contains only the `log-print` branch; production contains only `optical-frame` |
| Saga release, as published | 198,055 B JSON (99.0% of 200,000), 197,430 B CONF (over 180,000). Reproduced byte-for-byte |
| Saga release with `compress: true` | 198,805 B JSON (larger) |
| Saga on Linux | Fails as-is: the build is named `Saga` but the entry file is `lua/saga.lua`. It works on Windows' case-insensitive file system; CI on Linux needs a `Saga.lua` copy or alias |

## Stack versions on 2026-09-26

| Package | Version |
|---|---|
| next | 16.3.6 |
| @supabase/ssr | 0.12.7 |
| @supabase/supabase-js | 2.117.2 |
| tailwindcss | 4.3.3 |
| supabase (Python) | 2.31.0 |
| dxcam | 0.3.0 (released 2026-03, maintained again) |
| mss | 10.2.0 |
| pywin32 | 312 |
| keyring | 25.7.0 |
| pyinstaller | 6.22.3 |
| anthropic (Python) | 1.8.0 (needs Python 3.10+) |
| @wolfe-labs/du-luac | 1.3.5 (2024-03) |

## Still open, moved to spikes

Session 1 (2026-09-28) answered S0, S8, S10 and part of S3 and S4: see [spikes.md](spikes.md) and the [in-game addendum](#addendum-in-game-2026-09-28).

- Does `system.print` reach the disk log? (S0)
- The myDU client's log folder, whether EQU8 ships with it, and login automation (S8)
- `onInputText` fan-out across units, and whether a sidecar PB keeps running and receiving chat while the avatar sits in Saga's chair (S2; dropped by ADR-0002, since the bus now runs inside ArchHUD's unit)
- Chat key and input length limit (S3); Unicode `SendInput` vs scan codes (S4)
- Emitter behaviour through relays, and real ranges (S5); PB proximity radius (S6)
- CPU quota numbers with Saga running (S10)
- `system.modAction` size and rate limits, and whether plug-started units may call it (M1); which events `luaElementEmitEvent` can raise (M2). Both dropped by ADR-0003 (no server mods)
- du-socket internals: not needed while the protocol keeps its own framing

## Reproduce

```bash
docs/verification/sql/run.sh    # needs a scratch PostgreSQL 16; see the script header
docs/verification/luac/run.sh   # needs Node 18+ and the npm registry
```

Saga size check: clone tobitege/du-saga, copy `lua/saga.lua` to `lua/Saga.lua`, run `npx -p @wolfe-labs/du-luac@1.3.5 du-lua build`, then `ls -l out/release`.

## Addendum: ArchHUD

Checked after the owner picked ArchHUD ([ADR-0002](adr/0002-archhud-extension.md)).

| Repository | Commit | Date | Note |
|---|---|---|---|
| Archaegeo/Archaegeo-Orbital-Hud | da394e5 | 2023-10-02 | Upstream, version 2.103. Every branch ends in 2023 or earlier |
| The-Third-Verse/ArchHUD | 6c95222 | 2025-09-11 | The version the owner uses. Master is version 2.105 ("MyDU update"); last code change 2024-11-15, and the 2025 commit only deleted a zip. Other branches: `BetaMod` (2024-11-09) and `BetaStandalone` (2024-11-15), which is a single 231 KB config, version 0.105, without the `userclass` hook |
| samedicorp/ArchHUD | 6c95222 | 2025-09-11 | Same commit as The-Third-Verse/ArchHUD master; working trees compared identical |
| wolfe-labs/DU-ArchHUD | 2e59c74 | 2023-06-26 | Archive of upstream |
| Zer0Krypt/ArchHUD-MPRN | af64b8f | 2021-12-10 | Stale fork |

Line numbers below refer to commit 6c95222, The-Third-Verse/ArchHUD master.

| Fact | Evidence |
|---|---|
| Licensed GPL-3.0 | `LICENSE` |
| Modular: a 31 KB `ArchHUD.conf` plus about 467 KB of modules, loaded with `require` from `autoconf/custom/archhud/`. Does not run on GeForce Now | README; `src/ArchHUD.lua:160-163`; `wc -c src/requires/*.lua` |
| myDU changes: a custom atlas (the `customAtlas` parameter loads `autoconf/custom/<name>`), detection of new fuel tank types including anti-gravity fuel, and a fix for property saving | `ChangeLog.md` (2.104, 2.105); `src/ArchHUD.lua:15,153` |
| `archhud/userclass.lua` is loaded last, through `pcall(require, ...)` | `src/ArchHUD.lua:160-163`; `src/requires/userclass.example` |
| `userBase.ExtraOnStart`, `ExtraOnUpdate`, `ExtraOnFlush` and `ExtraOnStop` run at the end of each event | `baseclass.lua:590,664,679,723` |
| Overrides replace class functions by name, at the end of each constructor | `baseclass.lua:783`, `apclass.lua:3071`, `atlasclass.lua:981`, `controlclass.lua:826`, `hudclass.lua:2970` |
| `userScreen` is added to the HUD content. `setScreen` is only called when the content changes | `hudclass.lua:2107`; `baseclass.lua:654-655` |
| Timers: `apTick` at 60 Hz, `hudTick` at 15 Hz by default, `tenthSecond`, `oneSecond`. `program.onTick` ignores tags it does not know | `baseclass.lua:584-587,759`; `src/ArchHUD.lua:139` |
| Chat path: `script.onInputText` → `PROGRAM.controlInput` → `CONTROL.inputTextControl`, only after setup completes | `ArchHUD.conf` (`script.onInputText`); `baseclass.lua:745` |
| Unknown commands are ignored, but any chat line containing `::pos` is handled as add-waypoint. Adding waypoints is refused while the autopilot is on | `controlclass.lua:596,658,672` |
| Errors in handlers are printed but do not stop the unit | `ArchHUD.conf:58` (`__wrap_lua__stopOnError=false`) |
| In-process goto: a temporary location sets `AutopilotTargetIndex = 1`, then `ap.ToggleAutopilot()` engages. Same planet in atmosphere: vector to target with altitude hold. Space target: launch, then autopilot. Routes go through `apRoute` | `atlasclass.lua:864,889`; `apclass.lua:472-561` |
| Index 1 is whichever location sorts first by name in `AtlasOrdered`, not necessarily the new one. ArchHUD's own `::pos` handler relies on its name `0-Temp` sorting first; a name like `dub-j_1` sorts after the planets. So the bus looks its location up in `AtlasOrdered`, sets `AutopilotTargetIndex` and calls `ATLAS.UpdateAutopilotTarget()` itself | `atlasclass.lua:703-713,888-889`; `controlclass.lua:660` |
| Adding a temporary location whose name exists first `table.remove`s the old one from `atlas[0]`, which is keyed by body id, so later entries can shift. The bus never adds a name twice: it reselects its own location, or adds a suffix for a new place | `atlasclass.lua:878-883` |
| `AP.ToggleAutopilot()` flies the first stop of a loaded route (`apRoute`) instead of the selected target | `apclass.lua:529` |
| Globals the bus can use: `ATLAS`, `AP`, `AtlasOrdered`, `AutopilotTargetIndex`, `CustomTarget` (with `planetname`, `"Space"` off planets), `apRoute`, `BrakeIsOn`, `galaxyReference` and `sys`. `atlas` and the last-toggle time `apDoubleClick` are locals, so a pilot's toggle just before the bus's cannot be seen | `baseclass.lua:520-552`; `apclass.lua:16`; `globals.lua` |
| `galaxyReference[systemId][bodyId]` is the body with `center` (vec3) and `radius`. `::pos` converts to `center + (radius + alt) * (cos lat cos lon, cos lat sin lon, sin lat)`; body 0 means lat, lon and alt are world x, y and z | `atlasclass.lua:211-223,407-420`; `controlclass.lua:598-618` |
| A target counts as `"Space"` when it is farther from the closest body's center than its radius plus atmosphere thickness. On an airless moon that is anything above sea level | `atlasclass.lua:695-701` |
| `galaxyReference` cannot parse a `::pos` string: `mkMapPosition` calls a global `stringmatch` that ArchHUD only declares as a local. Its chat handler has its own converter, and the bus converts positions itself | `atlasclass.lua:131`; `baseclass.lua:15`; `controlclass.lua:598-618` |
| Two `ToggleAutopilot` calls within 1.5 s in atmosphere count as a double click (orbital hop altitude) | `apclass.lua:498` |
| `AP.clearAll()` clears every mode but leaves `BrakeIsOn`. `AP.BrakeToggle()` toggles, so it releases a set brake. `BrakeIsOn` can hold a string (`"BL Complete"`, `"Space Arrival"`, `"AP Finalizing"`), which counts as set | `apclass.lua:262-292,824-843` |
| Fuel: the globals `atmoTanks`, `spaceTanks` and `rocketTanks` list each tank as `{ id, name, max fuel mass, empty mass, ... }`. They are filled at start only while the fuel display is on (`fuelX` and `fuelY` not 0; the defaults are 30 and 700). The HUD shows `(element mass - empty mass) / max fuel mass` per tank, or the fuel slot widget's percentage for tanks linked to the seat. The percentages themselves stay local to the HUD | `baseclass.lua:252-281,333-343`; `hudclass.lua:2186-2192,2310-2330`; `ArchHUD.conf` (`fuelX`, `fuelY`) |
| How trips end: a landing clears `BrakeLanding` and `AltitudeHold` and sets `BrakeIsOn = "BL Complete"`; a space arrival (under 50 m/s at the target) clears `Autopilot` and sets `BrakeIsOn = "Space Arrival"`. `TurnBurn` is a braking preference that can stay set after the autopilot ends | `apclass.lua:2075-2085,2683-2692`; `controlclass.lua:188` |
| Other callable autopilot functions: `BrakeToggle`, `ResetAutopilots`, `ToggleAltitudeHold`, `ToggleIntoOrbit`, `BeginReentry`, `ToggleVerticalTakeoff`, `routeWP`, `cmdThrottle`, `cmdCruise` | `apclass.lua` |

`lua/spec/archhud_contract_spec.lua` checks the adapter's calls against this code. It loads the real `atlasclass.lua`, `apclass.lua` and `globals.lua` at the pinned commit, with the server's atlas, in a stubbed game. It confirms the target selection, the route precedence, the orbital hop on a quick second toggle, and the stop. It also confirms that engaging from the ground starts an auto takeoff that holds the brake (`BrakeIsOn = "ATO Hold"`).

Not verified here, moved to spikes (all four confirmed in session 1; see the [in-game addendum](#addendum-in-game-2026-09-28)):
- The modular ArchHUD 2.105 build installs and flies on the target server (A1).
- The `userclass` shim can wrap chat and timers as described (A2).
- The myDU client's install path for local Lua files (S8).
- Instruction headroom with the bus inside ArchHUD's unit (S10).

The server's atlas, checked when the probe kit was built:

| Repository | Commit | Date | Note |
|---|---|---|---|
| The-Third-Verse/AtlasFile | 48dd00f | 2025-09-12 | One `atlas.lua` (72 KB, Novaquark's atlas format, no licence file). Its README tells players to put it in `autoconf/custom/` and load it with `package.preload['atlas']`, so the `package` table is reachable from DU Lua. ArchHUD 2.105 loads `autoconf/custom/atlas.lua` by default, so no setting needs changing |

## Addendum: in game, 2026-09-28

Probe kit session 1 on The Third Verse, with ArchHUD 2.105 at the pinned commit ([spikes.md](spikes.md)). Line numbers refer to that commit.

| Fact | Evidence |
|---|---|
| The client runs Lua 5.4, with an instruction limit of 1,000,000 | The probe's `hello` line (`_VERSION`, `getInstructionLimit()`) |
| Files loaded with `require` do not see the handler slots: `system`, `unit` and the linked elements (`core`, `dbHud_1`, ...) are nil there | The probe's first run: `attempt to index a nil value (global 'system')`; `hello` line: `DUSystem=table system=nil unit=nil` |
| They do see `DUSystem` and the globals that handler code sets, such as `PROGRAM`, `script` and `Nav`. ArchHUD's own classes use `DUSystem`, `DUPlayer`, `DUConstruct` and `DULibrary` | `hello` line; `baseclass.lua:1-5`; `baseclass.lua:590` reads `PROGRAM`, which only `ArchHUD.conf` sets |
| Such a file gets the unit only as an argument. `ArchHUD.conf` passes it to `programClass` (as `u`), and its tick handler calls `script.onTick(timerId, unit)`, which hands only the tag on to `PROGRAM.onTick` | `ArchHUD.conf`: the `tick(timerId)` handler and `function script.onTick(h)PROGRAM.onTick(h)end` |
| An error that escapes a `userBase.ExtraOn*` hook reaches ArchHUD's startup wrapper ("ERROR STARTUP"), and the HUD does not appear | The probe's first run |
| `io`, `os` and `loadstring` are nil. `package` (with `loaded` and `preload`), `require`, `load`, `loadfile`, `dofile` and `debug` exist | `hello` line |
| After `package.loaded[name] = nil`, `require` reads the file from disk again, including changes made while the unit runs | S11 |
| `system.print` output does not reach the client's log | S0 |
| The client logs the first load of each local file ("Found ung override for lua load of ...") but not later re-reads | Session 1's log |
| ArchHUD calls `setAxisCommandValue` in flush. The client reports each call ("Executing a Lua method in the wrong thread ... Flush compatible:false"), about 60 times per second, still executes it, and the log grows by about 80 MB per hour | Logs of session 1 and of February 2026 |
| Timers fire on rendered frames: a 0.25 s timer fired 3.78 times per second | Probe panel: 14,155 ticks in 3,743 s |
| `userScreen` SVG is drawn one to one onto the screen at 2560×1600 (no scaling) | S1: a 6 px cell measured 6.00 px |
| `ArchHUD.conf` creates the global `Nav = Navigator.new(system, core, unit)`, and the game's `Navigator.lua` keeps its arguments as `Nav.system`, `Nav.core` and `Nav.control`. So a required file can reach the core and the unit through `Nav` (from the source; not yet used in game) | `ArchHUD.conf` (onStart); `Game/data/lua/Navigator.lua:24-29` |
