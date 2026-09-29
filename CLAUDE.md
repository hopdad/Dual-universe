# CLAUDE.md — mydu-fleet

## What this is
Client-side automation for myDU (self-hosted Dual Universe), only on servers whose admins permit it.
- Client-only: no server mods, no server APIs (ADR-0003). One real game client per bot (Windows 10/11, AVX).
- The bot bus runs inside ArchHUD's control unit, through ArchHUD's userclass.lua hook (ADR-0002).
- Lua (in-game) <-> transport <-> Python companion <-> Supabase hub <-> Next.js dashboard; Python LLM planner.

Where to look:
- Plan and decision gates: docs/plan.md. Decisions: docs/adr/. Wire protocol: docs/protocol.md.
- Verified facts with evidence: docs/verification.md (ArchHUD in its addendum).
- Todo list: "Next steps" in docs/plan.md. Spike results: docs/spikes.md.
- Moving from the cloud sessions to the owner's PC (Windows setup, lessons learned): docs/handoff/cloud-to-local.md.
- Original spec: docs/handoff/original-handoff.md (superseded wherever the documents above disagree).

## Hard facts (verified 2026-09-26; do not re-litigate)
Game API:
- system.logInfo/logWarning/logError were removed in Panacea (2022). Never use them.
- system.print, system.setScreen/showScreen and widgets only work when the player runs the unit explicitly (F),
  not when it was started by a plug signal. Plug-started worker boards report over emitters.
- Emitter.send is limited to 1 message per frame per channel; channels over 64 chars are not sent; messages are
  truncated at 512 chars.
- Container.updateContent and Industry.updateBank are limited to 1 call per 30 s. MiningUnit has no calibrate/start API.
- Timer resolution is bounded by the client's framerate.

In game (verified 2026-09-28, session 1; docs/verification.md, "Addendum: in game"):
- The client runs Lua 5.4. getInstructionLimit() is 1,000,000.
- Files loaded with require (all of dufleet/ and archhud/) do not see the handler slots: system, unit, core,
  dbHud_1 and other linked elements are nil there. Use DUSystem (also DUPlayer, DUConstruct, DULibrary), as
  ArchHUD's classes do. Globals set by handler code (PROGRAM, script, Nav) are visible. The unit arrives only
  as an argument: ArchHUD.conf's tick handler calls script.onTick(timerId, unit). ArchHUD keeps the unit and core
  in its global Nav (Nav.control, Nav.core) and passes the databank only to its constructors, AtlasClass (arg 5)
  and APClass (arg 9), during setup; the bus wraps them when the shim loads (lua/README.md).
- An error escaping a userBase.ExtraOn* hook stops ArchHUD's startup ("ERROR STARTUP", no HUD). Run every hook
  under pcall, and report errors with a print that cannot itself throw.
- A 0.25 s timer fires about 3.78 times per second (it waits for a rendered frame).
- ArchHUD's flush warnings ("wrong thread ... setAxisCommandValue") grow the client log by about 80 MB per hour.

Transports (ADR-0001, 2026-09-28):
- Out: O, an optical grid drawn through ArchHUD's userScreen and read by screen capture. Default 48x24 cells,
  2 bits, 6 px, 2 fps (4 px at 4 fps also decoded cleanly). L is dead: system.print never reaches the log (S0).
- In: F, the companion writes autoconf/custom/dufleet/inbox.lua (temp file, then rename) and the bus
  re-requires it every 0.5 s after clearing package.loaded. The file returns every pending command, not just
  the newest.
- Chat keystrokes, "/b <cseq> <verb> ... #<crc16>" with the CRC over the UTF-8 bytes between "/b " and " #",
  stay for manual tests; the injector is for login and menus only.
- Server mods (system.modAction, CPPMod.*) are out of scope (ADR-0003).

ArchHUD (The-Third-Verse/ArchHUD 2.105, modular master build, commit 6c95222, GPL-3.0; samedicorp/ArchHUD is the
same commit):
- Installed as local files under Game/data/lua/autoconf/custom/ (ArchHUD.conf plus archhud/). No paste-size limit applies.
- The BetaStandalone branch is a single-file build with no userclass hook. Never use it for bots.
- The server is The Third Verse. Its atlas (The-Third-Verse/AtlasFile at 48dd00f) goes to autoconf/custom/atlas.lua,
  where ArchHUD 2.105 loads it by default (customAtlas = "atlas"). Tests are also allowed on Settlers, whose
  atlas is unchecked; the file applies on every server the client joins.
- archhud/userclass.lua is loaded last. userBase.ExtraOnStart/Stop/Update/Flush run at the end of each event;
  userX.fn replaces a class function by name.
- The global userScreen is added to ArchHUD's setScreen content. Nothing else may call system.setScreen on that unit.
- Chat path: script.onInputText -> PROGRAM.controlInput -> CONTROL.inputTextControl.
  - Any line containing "::pos" is treated as add-waypoint.
  - So the bus intercepts /b lines first (it wraps PROGRAM.controlInput at start).
  - And /b arguments never contain "::pos": write pos=sys,body,lat,lon,alt.
- Timers: script.onTick -> PROGRAM.onTick, which ignores unknown tags. The bus wraps it for its "dub" tag.
- goto = ATLAS.AddNewLocation(name, worldPos, true), which selects the location sorting first by name, so then set
  AutopilotTargetIndex from AtlasOrdered and call ATLAS.UpdateAutopilotTarget(); then one AP.ToggleAutopilot(). Two
  calls within 1.5 s in atmosphere mean "orbital hop". Never add a location name twice (ArchHUD's replace path
  table.remove()s its body-id keyed atlas). A loaded apRoute takes precedence over the selected target.
- Stop = AP.clearAll(), AP.cmdThrottle(0), then AP.BrakeToggle() only if BrakeIsOn is unset (strings count as set).
- Handler errors print but do not stop the unit; a CPU overload does. ArchHUD runs a 60 Hz autopilot timer and a
  15 Hz HUD tick.
- ArchHUD writes only its own keys to dbHud_1 and never clears it. Our keys use the "dub." prefix there.

Game files:
- The only game files we write are archhud/userclass.lua and autoconf/custom/dufleet/, plus, at install,
  ArchHUD's own files, atlas.lua, and backups under autoconf/custom/_dufleet_backup/. Never read or modify
  client memory.
- Files copied into autoconf/custom/ through a UAC prompt belong to Administrators; replacing them needs a
  one-time Modify grant for the user's account (icacls, from an admin terminal). The installer checks first.

## Stack and conventions
- lua/:
  - Plain Lua modules for dufleet/ plus the userclass.lua shim; no DU-LuaC project. The game runs 5.4 and
    CI tests on 5.3, so write code that runs on both.
  - All ArchHUD access goes through dufleet/archhud_adapter. Every entry point runs in pcall.
  - Timers only; no bot work in onUpdate/onFlush.
  - Tests: busted + du-mocks + a fake-ArchHUD harness, plus a contract spec against the real pinned ArchHUD
    code (tools/deps.sh fetches it); luacheck.
- companion/:
  - Python 3.12, uv, pydantic, asyncio, pytest; supabase-py async client (realtime on_postgres_changes with filter).
  - Win32 code isolated in proc/ and inject/; all input goes through inject/focus.py (verify the foreground HWND
    before and after). One global input mutex.
  - `install` and `doctor` verify the ArchHUD and bus files by hash.
- supabase/:
  - SQL migrations only. RLS on every table, including command_seq.
  - cseq is assigned by the server and immutable; one command in flight per bot; claims take a lease.
  - Device users move commands and report status only through RPCs (claim_next_command, recover_inflight,
    command_progress, bot_report, sync_epoch, and request_resend, the one command they may queue), never the
    service role. Column grants keep epoch, cseq, status and
    ownership out of client writes.
  - Scenario tests: supabase/tests/run.sh on plain PostgreSQL (docs/verification/sql keeps the handoff comparison).
- dashboard/:
  - Next.js 16 App Router: proxy.ts, not middleware.ts.
  - @supabase/ssr with getAll/setAll cookies, getClaims(), and the publishable key.
  - Server components by default; Tailwind; no emoji; dense tables.
- packages/protocol/:
  - Single source of truth (protocol.schema.json, vectors.json, skills.json); regenerate constants and the hub's
    skills seed, never hand-edit.
  - Outbound lines are split at most 7 times (the JSON body may contain "|").
- planner/: anthropic SDK; model ID from config (check the current model list when Phase 4 starts); tools generated
  from the skills registry.
- Conventional commits. Protocol changes bump docs/protocol.md and vectors.json.

## Current phase: 1 (Phase 0's in-game session ran on 2026-09-28; docs/spikes.md, ADR-0001)
- The bus no longer reads the handler slots (done offline 2026-09-28; step 12 checks it in game, spike S12).
  Next: the transports O and F ("Next steps" in plan.md).
- The probe kit is in spikes/, with the session script in spikes/README.md. Its tests run offline:
  cd spikes/host && uv run pytest (the Lua parts need lua5.3 on PATH; they also run on Windows).
- Pinned upstream files and their SHA-256 live in spikes/host/src/dufleet_probe/pins.py.
- Tests: cd lua && ./tools/deps.sh && busted && luacheck . ; cd companion && uv run pytest && uv run ruff check .
  cd dashboard && npm run lint && npm run typecheck && npm test && npm run build && npm run e2e
  After a schema change: python packages/protocol/codegen.py, then (in companion/)
  uv run python ../packages/protocol/tools/make_vectors.py.
- CI (.github/workflows/ci.yml) runs all of these plus supabase/tests/run.sh on PostgreSQL 16, and the pump tests
  against the real hub SQL, including the full chain with the real Lua bus (companion/tests/test_pump_pg.py and
  test_fullstack_pg.py, opt-in locally with DUFLEET_PG_TESTS=1).

## When unsure
- DU API behaviour not in the Codex or du-mocks: add a spike to docs/spikes.md; do not guess.
- ArchHUD behaviour: read the pinned source (The-Third-Verse/ArchHUD at 6c95222), not the user manual.
- Small testable modules; a fixture for every parser.
