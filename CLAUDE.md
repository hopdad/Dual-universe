# CLAUDE.md — mydu-fleet

## What this is
Client-side automation for myDU (self-hosted Dual Universe), only on servers whose admins permit it.
- Client-only: no server mods, no server APIs (ADR-0003). One real game client per bot (Windows 10/11, AVX).
- The bot bus runs inside ArchHUD's control unit, through ArchHUD's userclass.lua hook (ADR-0002).
- Lua (in-game) <-> transport <-> Python companion <-> Supabase hub <-> Next.js dashboard; Python LLM planner.

Where to look:
- Plan and decision gates: docs/plan.md. Decisions: docs/adr/.
- Verified facts with evidence: docs/verification.md (ArchHUD in its addendum).
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

Transports (ADR-0001 pending):
- Out: L (log tail; spike S0, probably dead) or O (optical grid drawn through ArchHUD's userScreen).
- In, one of:
  - F: the companion writes autoconf/custom/dufleet/inbox.lua and the bus re-requires it (spike S11);
  - C: chat keystrokes, "/b <cseq> <verb> ... #<crc16>", with the CRC over the UTF-8 bytes between "/b " and " #".
- Server mods (system.modAction, CPPMod.*) are out of scope (ADR-0003).

ArchHUD (The-Third-Verse/ArchHUD 2.105, modular master build, commit 6c95222, GPL-3.0; samedicorp/ArchHUD is the
same commit):
- Installed as local files under Game/data/lua/autoconf/custom/ (ArchHUD.conf plus archhud/). No paste-size limit applies.
- The BetaStandalone branch is a single-file build with no userclass hook. Never use it for bots.
- The server is The Third Verse. Its atlas (The-Third-Verse/AtlasFile at 48dd00f) goes to autoconf/custom/atlas.lua,
  where ArchHUD 2.105 loads it by default (customAtlas = "atlas").
- archhud/userclass.lua is loaded last. userBase.ExtraOnStart/Stop/Update/Flush run at the end of each event;
  userX.fn replaces a class function by name.
- The global userScreen is added to ArchHUD's setScreen content. Nothing else may call system.setScreen on that unit.
- Chat path: script.onInputText -> PROGRAM.controlInput -> CONTROL.inputTextControl.
  - Any line containing "::pos" is treated as add-waypoint.
  - So the bus intercepts /b lines first (it wraps PROGRAM.controlInput at start).
  - And /b arguments never contain "::pos": write pos=sys,body,lat,lon,alt.
- Timers: script.onTick -> PROGRAM.onTick, which ignores unknown tags. The bus wraps it for its "dub" tag.
- goto = ATLAS.AddNewLocation(name, worldPos, true), then one AP.ToggleAutopilot(). Two calls within 1.5 s in
  atmosphere mean "orbital hop".
- Handler errors print but do not stop the unit; a CPU overload does. ArchHUD runs a 60 Hz autopilot timer and a
  15 Hz HUD tick.
- ArchHUD writes only its own keys to dbHud_1 and never clears it. Our keys use the "dub." prefix there.

Game files:
- The only game files we write are archhud/userclass.lua and autoconf/custom/dufleet/ (plus ArchHUD's own files
  at install). Never read or modify client memory.

## Stack and conventions
- lua/:
  - Plain Lua 5.3 modules for dufleet/ plus the userclass.lua shim; no DU-LuaC project.
  - All ArchHUD access goes through dufleet/archhud_adapter. Every entry point runs in pcall.
  - Timers only; no bot work in onUpdate/onFlush.
  - Tests: busted + du-mocks + a fake-ArchHUD harness; luacheck.
- companion/:
  - Python 3.12, uv, pydantic, asyncio, pytest; supabase-py async client (realtime on_postgres_changes with filter).
  - Win32 code isolated in proc/ and inject/; all input goes through inject/focus.py (verify the foreground HWND
    before and after). One global input mutex.
  - `install` and `doctor` verify the ArchHUD and bus files by hash.
- supabase/:
  - SQL migrations only. RLS on every table, including command_seq.
  - cseq is assigned by the server and immutable; one command in flight per bot; claims take a lease.
  - Device users write through RPCs (claim_next_command, bot_report, recover_inflight), never the service role.
  - Scenario tests from docs/verification/sql run in CI.
- dashboard/:
  - Next.js 16 App Router: proxy.ts, not middleware.ts.
  - @supabase/ssr with getAll/setAll cookies, getClaims(), and the publishable key.
  - Server components by default; Tailwind; no emoji; dense tables.
- packages/protocol/:
  - Single source of truth (protocol.schema.json, vectors.json); regenerate constants, never hand-edit.
  - Outbound lines are split at most 7 times (the JSON body may contain "|").
- planner/: anthropic SDK; model ID from config (check the current model list when Phase 4 starts); tools generated
  from the skills registry.
- Conventional commits. Protocol changes bump docs/protocol.md and vectors.json.

## Current phase: 0, with transport-independent Phase 1 work in parallel
- Spikes to run first: S9, S8, A1, A2, S11, S0, S1.
- The probe kit is in spikes/, with the session script in spikes/README.md. Its tests run offline:
  cd spikes/host && uv run pytest (needs lua5.3 on PATH).
- Pinned upstream files and their SHA-256 live in spikes/host/src/dufleet_probe/pins.py.
- Transport adapters wait for ADR-0001. The protocol package, the hub schema, the dashboard skeleton and the Lua
  and companion cores do not.

## When unsure
- DU API behaviour not in the Codex or du-mocks: add a spike to docs/spikes.md; do not guess.
- ArchHUD behaviour: read the pinned source (The-Third-Verse/ArchHUD at 6c95222), not the user manual.
- Small testable modules; a fixture for every parser.
