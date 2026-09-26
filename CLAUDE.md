# CLAUDE.md — mydu-fleet

## What this is
Client-side automation for myDU (self-hosted Dual Universe), only on servers whose admins permit it.
One real game client per bot (Windows 10/11, AVX); Lua runs in that client.
Lua (in-game) <-> transport <-> companion and/or server mod <-> Supabase hub <-> Next.js dashboard; Python LLM planner.

- Plan and decision gates: docs/plan.md
- Verified facts with evidence: docs/verification.md
- Original spec: docs/handoff/original-handoff.md (superseded wherever the two above disagree)

## Hard facts (verified 2026-09-26; do not re-litigate)
- system.logInfo/logWarning/logError were removed in Panacea (2022). Never use them.
- system.print, system.setScreen/showScreen and widgets only work when the player runs the unit explicitly (F),
  not when it was started by a plug signal. Plug-started worker boards report over emitters.
- Whether system.print reaches the disk log is spike S0.
- Transports:
  - M (myDU mod): out via system.modAction; in via modinjectjs plus CPPMod.luaElementEmitEvent.
  - L: log tail.
  - O: optical HUD grid.
  - C: chat keystrokes in.
  - Chosen per server in ADR-0001 and ADR-0003.
- system.modAction and CPPMod.* are myDU additions, absent from the Codex and du-mocks. Stub them in tests;
  check dual-universe/mydu-server-mods before assuming behaviour.
- Commands over chat (track C) are "/b <cseq> <verb> ... #<crc16>" via system:onEvent('onInputText', ...).
  The CRC covers the UTF-8 bytes between "/b " and " #". Saga silently ignores /b lines.
- DU-LuaC paste limits are 200,000 B JSON and 180,000 B CONF. Saga's release build is 198,055 B, so none of our
  code goes inside Saga's unit. Topology (sidecar bus PB vs trimmed fork) is ADR-0002.
- Saga redraws its whole HUD with one system.setScreen call every frame. Nothing else may call setScreen on that unit.
- Saga /goto:
  - Standard mode: sets the autopilot target and switches the autopilot on.
  - Maneuver mode (VTOL only): climbs, aligns, traverses and lands.
  - Abort = brake (CTRL).
- Emitter.send is limited to 1 message per frame per channel; channels over 64 chars are not sent; messages are
  truncated at 512 chars.
- Container.updateContent and Industry.updateBank are limited to 1 call per 30 s. MiningUnit has no calibrate/start API.
- Never modify game files outside the Lua autoconf folders; never read or modify client memory.

## Stack and conventions
- lua/:
  - DU-LuaC 1.3.5, "cli": {"fmtVersion": 5}. Slots are {"name": ..., "type": ...} using DU-LuaC type keys
    (core, databank, telemeter, emitter, receiver, screen). Entry file = build name (src/bus.lua).
  - Events via obj:onEvent('onX', fn). Links via library.getLinksByClass with in-game classes
    (DataBankUnit, ScreenUnit, IndustryUnit, ...).
  - Tests: busted on Lua 5.3 + du-mocks.
  - Databank keys prefixed "dub.", on the bus's own databank.
  - Timers only (unit.setTimer); no bot work in onUpdate/onFlush.
- companion/:
  - Python 3.12, uv, pydantic, asyncio, pytest; supabase-py async client (realtime on_postgres_changes with filter).
  - Win32 code isolated in proc/ and inject/; all input goes through inject/focus.py (verify the foreground HWND
    before and after). One global input mutex.
- supabase/:
  - SQL migrations only. RLS on every table, including command_seq.
  - cseq is assigned by the server and immutable; one command in flight per bot; claims take a lease.
  - Device users write through RPCs (claim_next_command, bot_report, recover_inflight), never the service role.
  - Scenario tests from docs/verification/sql run in CI.
- dashboard/:
  - Next.js 16 App Router: proxy.ts, not middleware.ts.
  - @supabase/ssr with getAll/setAll cookies, getClaims(), and the publishable key.
  - Server components by default; Tailwind; no emoji; dense tables.
- mod/ (track M only): C# net6.0 myDU DLL mod; the assembly name starts with "Mod".
- packages/protocol/:
  - Single source of truth (protocol.schema.json, vectors.json); regenerate constants, never hand-edit.
  - Outbound lines are split at most 7 times (the JSON body may contain "|").
- planner/: anthropic SDK; model ID from config (check the current model list when Phase 4 starts); tools generated
  from the skills registry.
- Every Lua build's size is reported in CI; CI fails above 90% of the JSON paste limit.
- Conventional commits. Protocol changes bump docs/protocol.md and vectors.json.

## Current phase: 0 (spikes and decision gates), with transport-independent Phase 1 work in parallel
See docs/plan.md. Transport adapters wait for ADR-0001..0003. The protocol package, the hub schema,
the dashboard skeleton and the Lua and companion cores do not.

## When unsure
- DU API behaviour not in the Codex or du-mocks: add a spike to docs/spikes.md; do not guess.
- Small testable modules; a fixture for every parser.
