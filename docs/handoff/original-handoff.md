# myDU Client-Side Bot Fleet: Implementation Spec and Claude Code Handoff

The architecture can be built, but the telemetry-out part of the chosen design is probably broken. In the Panacea update (2022), Novaquark removed the Lua functions that wrote to the client log, and no public source confirms that `system.print` output still reaches the log file. So the telemetry channel has to be proven in-game before anything else is built. This spec uses a transport-agnostic protocol with a fallback: an "optical" frame drawn on the HUD and decoded from screenshots.

Process note: the enrichment pass did not run because the draft was over the tool's size limit, so no claims were swapped for enricher-sourced versions. Every sourced fact below comes from pages I fetched or search snippets I read. Unverified items are flagged.

## TL;DR

- **Telemetry out is the critical unknown.**
  - Novaquark's Panacea devblog says `system.logInfo()`, `system.logWarning()` and `system.logError()` "are now completely removed", because writing to the log "allowed the creation of bots".
  - Every log-based community tool is marked deprecated (ZarTaen's audio framework: "DEPRECATED AS OF 0.28"; DU-Audio-Sharp).
  - Spike S0 (does `system.print` reach the logs under `%LOCALAPPDATA%\NQ\DualUniverse\`?) must pass before Phase 1 starts. The protocol works over either a log tail or an optical HUD frame.
- **Commands in via Lua chat is solid.**
  - Saga (tobitege/du-saga, version 4.1.6.2 from 2025-09-01, GPL-3.0, built with DU-LuaC) already runs a full autopilot from chat commands: `/goto ::pos{...}`, `/go`, `/current`, `/setBase`.
  - Fork Saga and put the bot bus inside it. Don't wrap YFS: its author published it only so "someone else may continue the development".
- **Build order:**
  - Phase 0: spikes.
  - Phase 1: one client, a proven telemetry channel, a chat command dispatcher with acks, the Supabase hub, and a Next.js fleet grid.
  - Phase 2: skills (Saga goto, haul, industry, patrol, mine).
  - Phase 3: several clients plus an emitter/receiver relay.
  - Phase 4: LLM planner and vision loop.
  - The CLAUDE.md in section 11 covers Phases 0 and 1.

## Key Findings (verified facts and what they change)

| Topic | Verified fact | Source | Design consequence |
|---|---|---|---|
| Lua log writing | "We have decided to remove the ability to write lines directly to the clients log files using Lua... allowed the creation of bots". Removed: `system.logInfo()`, `system.logWarning()`, `system.logError()` | NQ forum devblog "Panacea Lua Changes" (NQ-Wanderer, Jan 17 2022, via search snippet); MassivelyOP summary (Jan 18 2022) | Don't rely on `logInfo`. Whether `system.print` reaches the log is unverified (spike S0) |
| Status of log-based tools | DU-Audio-Sharp: "Dual Universe has removed support for lua logfile interaction... This will no longer work in modern version of Dual Universe" | Dimencia/DU-Audio-Sharp README | wolfe-labs/DU-LogFramework is useful only as a parsing reference. It is a self-described prototype (Node) and doesn't prove the channel still works |
| NQ stripping log data | "Automatic upload is currently deactivated because NQ removed relevant data from the logs" | tiramon/du-map-companion README | NQ has removed useful data from the logs more than once |
| Log location | `%localappdata%\NQ\DualUniverse\`. Session logs are `.xml` files, reachable via "Debug Settings... Show Logs" | NQ Support article; PCGamingWiki | The tailer watches the newest `*.xml` in that tree. Confirm the exact subfolder and file naming in S0 |
| Log encoding | du-map-companion fixed a crash "when there were non utf8 characters in the log file" | tiramon release notes (subagent) | Decode with `errors="replace"` |
| Forum reaction | "Since the log function has been removed, there is no longer a way to copy text from within the game". A player (Wolfram) predicted exploiters "will probably use QR/bar codes + OCR" | Panacea discussion thread (snippets) | The optical channel is the known workaround. It's sensitive with NQ, so get each myDU admin's consent |
| Chat commands | Saga's `/goto ::pos{0,2,35.3951,104.1187,285.5413}`, `/go`, `/current` ("Outputs in LUA chat the current position"), `/setBase`, `/goAlt`, `/vertical` | tobitege/du-saga README | The `onInputText` chat-command pattern is proven |
| Saga maintenance | 4.1.6.2 from 2025-09-01; GPL-3.0; DU-LuaC; "should also work on GFN as it does not require any 3rd party files". Repo updated Apr 2026 | du-saga README; GitHub topics | This is the fork target |
| Saga constraints | "Maneuver mode does NOT allow to Autopilot via routes!"; needs a pilot chair or remote controller, 1–2 databanks; telemeter "highly recommended (up to 100m ground detection)"; the unminified build "is not usable due to its size" | du-saga README | The skill must check links and flight mode. Production builds must be minified |
| YFS | "made public so that someone else may continue the development"; strict link order | PerMalmberg/du-yfs README | Use as reference only |
| DU-LuaC | `obj:onEvent('onEventName', handler, ref)`; `library.getLinksByClass()`; `library.embedFile()`; `---@if` directives; `"cli": {"fmtVersion": 2}` | @wolfe-labs/du-luac npm README | Use project format v2 and find linked elements by class |
| Emitter/receiver quirk | Receiver → PB works; Receiver → Manual Switch/Relay → PB is "not working"; the 1000 m range is disputed | DU forum "Receiver / Emitter are useless?" (Mar 2023) | Link the receiver directly to the running PB. No relay chains |
| Offline testing | du-mocks: "Mock objects ... for use testing Dual Universe scripts offline"; `luarocks install du-mocks`; the codex was last generated 2024-09-27 | 1337joe/du-mocks | Test harness: busted + du-mocks |
| Platform | DU "only runs under Windows 10/11"; AVX required | NQ Support | The companion is Windows-only. VMs need AVX |
| Anti-cheat (official MMO) | EQU8 forbids modifying game files "except for the Game/data/lua folder" | NQ Support EQU8 article | Never touch the client binaries or cache. Whether the myDU client ships EQU8 is unverified |
| myDU server mods | The toolkit offers "A client API allowing code to perform gameplay actions as a logged in player" | dual-universe/mydu-server-mods | Out of scope here, but it's the clean path if an admin cooperates |
| du-tools | Described only as "server mods, MCP bridge automation, live Lua authoring, RenderScript emulator, and data/export utilities" | GitHub topics | I couldn't read the README. Treat its AHK and screenshot patterns as inspiration only |

## Details

### 0. Transport decision tree

```
S0: system.print("@@DUB|probe|<nonce>") appears in newest %LOCALAPPDATA%\NQ\DualUniverse\**\*.xml ?
 ├─ YES, <2 s, unthrottled → Transport L (log tail). Measure max line, rate limit, escaping.
 ├─ YES but delayed/truncated → L for events/acks, O for 1 Hz telemetry.
 └─ NO → Transport O (optical HUD frame) for everything.
```

- **Transport L (log tail):**
  - The companion tails the newest log file and keeps only lines containing the `@@DUB|` marker.
  - It parses each XML record and unescapes the XML entities.
  - The exact record schema gets captured as a fixture in S0.
- **Transport O (optical frame):**
  - Lua draws a block grid with fixed geometry via `system.setScreen` (HTML/SVG), or on a screen unit in the avatar's view.
  - Layout: 4 corner fiducials plus a 48×24 grid of 2-bit cells (4 colours), which is 288 bytes raw.
  - Each frame carries a 16-byte header (magic, frame sequence, message id, chunk i/n, length), a CRC16, and about 270 bytes of payload.
  - The companion captures that region with dxcam/mss at 10 Hz, warps it back to a flat grid, samples the cells, checks the CRC, and drops duplicate frames by sequence number.
  - At 2–4 frames per second this gives roughly 0.5–1 KB/s, which covers 1 Hz telemetry plus events.
  - The calibration command `/b cal` draws a known test pattern.
  - Fallback: large base32 text read with Tesseract.
  - Only use Transport O where the admin allows automation.
- **Transport C (commands in):** keystrokes into the Lua chat tab, read by `system.onInputText(text)`.

### 1. Monorepo layout

```
mydu-fleet/
├─ CLAUDE.md  README.md
├─ docs/ protocol.md  spikes.md  ingame-setup.md  adr/0001-transport.md  adr/0002-saga-fork.md
├─ packages/protocol/ protocol.schema.json  vectors.json  codegen/ (→ Lua/Py/TS constants)
├─ lua/                        # DU-LuaC project
│  ├─ project.json
│  ├─ src/main.lua
│  ├─ src/bus/{json.lua,frame.lua,transport_log.lua,transport_optical.lua,outbox.lua}
│  ├─ src/cmd/{parser.lua,dispatcher.lua,builtin.lua}
│  ├─ src/skills/{runtime.lua,goto.lua,mine_loop.lua,haul_route.lua,industry.lua,patrol.lua}
│  ├─ src/telemetry/{collectors.lua,emitter.lua}
│  ├─ src/relay/{node.lua,worker_main.lua}
│  ├─ src/persist/db.lua   src/util/{pos.lua,vec.lua,budget.lua}
│  ├─ vendor/saga/             # git subtree tobitege/du-saga (GPL-3.0)
│  └─ tests/                   # busted + du-mocks
├─ companion/                  # Python 3.12, Windows
│  ├─ pyproject.toml  bots/bot01.toml  ahk/chat_send.ahk
│  └─ src/dufleet/{__main__.py,config.py,
│       proc/{window,launcher,login}.py, ingest/{log_tailer,xml_record,optical,deframer}.py,
│       inject/{focus,sender_sendinput,sender_ahk,chat}.py, capture/{screen,regions}.py,
│       hub/{supabase_client,command_pump,telemetry_sink}.py, health/{watchdog,heartbeat,states}.py,
│       vision/{vlm_client,ui_actions}.py, protocol/{envelope,grammar,crc}.py}
├─ dashboard/                  # Next.js App Router + Tailwind
│  ├─ app/(auth)/login/page.tsx
│  ├─ app/(app)/{fleet,bots/[id],map,commands,goals,logs}/page.tsx
│  ├─ components/{BotCard,TelemetrySpark,MapCanvas,CommandComposer,GoalTree,EventLog}.tsx
│  ├─ lib/{supabase/server.ts,supabase/client.ts,du/pos.ts,du/bodies.ts,protocol.ts}
│  └─ middleware.ts
├─ planner/src/planner/{loop,tools,memory,recovery,vision_loop}.py  prompts/
└─ supabase/ config.toml  migrations/0001_core.sql..0004_retention.sql  seed.sql
```

### 2. Wire protocol (v1)

**Outbound (Lua → companion), one frame per line or optical payload:**

```
@@DUB|1|<bot>|<kind>|<seq>|<i/n>|<crc16hex>|<body>
```

- **Fields:**
  - `1` is the protocol major version. The companion rejects unknown majors.
  - `bot` is the id stored in the databank (set with `/b setid`).
  - `kind` is one of `T` telemetry, `E` event, `A` ack, `N` nack, `H` hello/heartbeat, `R` skill result, `D` debug.
  - `seq` is a u32 counter per boot. `H` carries a `boot` id so the companion can detect restarts.
  - The CRC is CRC-16/CCITT-FALSE over the chunk's body.
- **Body:** compact JSON. If it's over `MAXLINE`, it's split into base64 chunks. `MAXLINE` is measured in S0; default 400.

```json
{"boot":"k3f9","v":"0.3.1","unit":"pb","slots":["core","db"],"skill":"idle","q":0}
{"p":"::pos{0,2,35.3951,104.1187,285.5413}","w":[0,0,0],"v":12.4,"alt":285.5,"fuel":{"atmo":0.82},"cargo":0.41,"st":"goto:travel"}
{"ev":"skill_state","skill":"goto","from":"align","to":"travel","job":"j_7a1"}
{"ref":1042,"job":"j_7a1","ok":true}
{"ref":1042,"err":"E_BUSY","msg":"skill mine running"}
{"job":"j_7a1","skill":"goto","ok":true,"data":{"dist":3.2,"t":184}}
```

**Inbound chat grammar:**

```
/b <cseq> <verb> [args...] #<crc16hex>
verb := ping | status | cancel [job] | pause | resume | setid <id> | cal | resend <fromSeq>
      | run <skill> <job> key=value... | relay <chan> <b64> | db get|set <k> [v]
long payloads: /b <cseq> part i/n <b64> ... then /b <cseq> commit #crc
```

The chat input length limit hasn't been measured (spike S3).

**Reliability:**
- **Delivery and idempotency.** Commands are delivered at least once and executed at most once. Lua keeps a ring of the last 64 `cseq` values and saves the last one to the databank. On a duplicate it re-sends the original ACK and doesn't run the command again.
- **Timeouts and retries.** The ACK timeout is 3 s on Transport L and 5 s on Transport O. After a timeout the companion re-checks window focus and chat state, retypes, and retries up to 3 times (1/3/8 s backoff). After that it marks the command `failed_delivery` and raises an incident.
- **Ordering.** Only one un-acked command per bot at a time. An ACK means the command was accepted. The result arrives later as `R`.
- **Lost outbound frames.** `T` is fire-and-forget, and only the latest value is kept. `E`, `R` and `A` sit in a 32-entry replay ring, recoverable with `resend`.
- **Versioning.** The major version is on every line. `H` carries the script semver, and the dashboard flags bots whose script version differs from the rest.

### 3. Lua side

**Modules:**
- `frame.lua`: encoding, chunking, and a table-driven CRC16.
- `outbox.lua`: priority A/N > E/R > T, rate-limited to 2 lines per 0.25 s tick. Consecutive `T` frames are merged.
- `dispatcher.lua`: registers with `system:onEvent('onInputText', ...)` and ignores anything that doesn't start with `/b `, so Saga's own commands still work.
- `runtime.lua`: each skill is a coroutine with `start(args, ctx)`, `step(ctx)` returning `running`, `done` or `failed`, and `cancel(ctx)`. It is resumed on a timer with a per-tick step budget. One active skill at a time.

**Skills:**
- `goto`: validate → set mode → call Saga's `/goto` pipeline in-process through the adapter → wait → check arrival (under the distance tolerance and under 1 km/h for 5 s).
- `haul_route`: a sequence of `goto` legs plus dock actions, reading linked containers.
- `industry`: finds units with `library.getLinksByClass('IndustryUnit')`, restarts stopped ones, and emits state events. Big factories need several PBs because of link-slot limits.
- `patrol`: cycles through waypoints with a dwell time, reporting radar contacts.
- `mine_loop`: wait for this until S7 settles which mining actions Lua can reach and which are UI-only.

**CPU budget:**
- DU enforces a per-unit CPU quota and stops the script with an overload error. That's widely reported, but I didn't verify the exact numbers.
- Bot work runs only on `unit.setTimer('bot', 0.25)`, never in `onUpdate`/`onFlush`.
- Collectors run round-robin: position every tick, cargo every 4th tick, industry every 8th.
- The optical SVG is only rebuilt when the frame changes.
- Soak-test Saga and the bus together for 2 hours.

**Databank keys (`dub.` prefix):**

| Key | Contents |
|---|---|
| `dub.schema` | Schema version |
| `dub.id` | Bot id |
| `dub.boot` | Current boot id |
| `dub.cseq_last` | Last executed command sequence |
| `dub.job` | Active job as JSON, for resume |
| `dub.wps.<name>` | Waypoint lists |
| `dub.cfg` | Config (tick, maxline, transport) |

Use a second databank, or strict namespacing, so these don't collide with Saga's keys.

**Slot linking:**
- **Pilot unit** (Saga remote controller or chair):
  - core, databank(s), telemeter, hovers/vertical boosters
  - warp drive, AGG and radar if present
  - a screen, if Transport O uses a screen unit
  - an emitter (Phase 3)
- **Worker PB:** core, databank, a receiver linked directly to the PB, an emitter, plus industry units and containers.

**project.json** (check field names against the DU-LuaC wiki "Getting Started" page for your version):

```json
{
  "cli": { "fmtVersion": 2 },
  "name": "mydu-fleet",
  "sourcePath": "src",
  "outputPath": "out",
  "builds": [
    { "name": "pilot",  "slots": { "core": {"type":"CoreUnit"}, "db": {"type":"DatabankUnit"},
      "tele": {"type":"TelemeterUnit"}, "emit": {"type":"EmitterUnit"}, "screen": {"type":"ScreenUnit"} } },
    { "name": "worker", "slots": { "core": {"type":"CoreUnit"}, "db": {"type":"DatabankUnit"},
      "rx": {"type":"ReceiverUnit"}, "tx": {"type":"EmitterUnit"} } }
  ],
  "targets": [
    { "name": "development", "minify": false, "variables": { "debug": true,  "transport": "log" } },
    { "name": "production",  "minify": true,  "variables": { "debug": false, "transport": "optical" } }
  ]
}
```

Use `---@if transport "optical"` to compile out whichever transport isn't used.

**Sandbox:**
- Community reports say there's no HTTP or file I/O. Panacea closed the log-writing path.
- Assume the only ways out are chat, the HUD, screens, emitters and databanks.
- In S0, confirm that the `io` and `os` globals are absent.

**Fan-out (Phase 3):**
- The pilot PB calls `emitter.send(channel, payload)`. Worker PBs listen on a receiver, reuse the same `frame.lua`, and ACK back over their own emitter.
- Workers need an activated PB and a player nearby. About 35 m has been reported; measure it in S6. The detection-zone reactivation trick keeps them alive while the bot avatar stays parked in range.
- EliasVilld/du-socket and du-serializer are possible framing references. I didn't check their internals.

**Saga fork plan:**
- Add Saga as a git subtree.
- Initialise the bus from Saga's unit start.
- Add `SagaAdapter.goto(pos)`, `state()` and `abort()`.
- Keep Saga's native chat commands working.
- GPL-3.0 applies to the combined build.
- Borrow route-over-tile logic from YFS; Saga lists it as a TODO.

### 4. Python companion

- **Windows (`proc/`):**
  - Find the client window with pywin32 (`EnumWindows`, `GetWindowThreadProcessId`) and pin its size and position.
  - Login goes through the launcher using vision or template-checked AHK macros (spike S8).
- **Log tailer:**
  - Polls every 250 ms for the newest `*.xml` (recursive) under `%LOCALAPPDATA%\NQ\DualUniverse\`.
  - Switches files on rotation, and rewinds if the file shrinks (size < offset).
  - Decodes UTF-8 with `errors="replace"`.
  - Uses a lenient record splitter, because the file is incomplete XML while it's being written.
  - Unescapes entities, filters on `@@DUB|`, and passes frames to the deframer.
- **Optical reader:**
  - dxcam capture of a set region at 10 Hz.
  - Fiducial template match, perspective warp, then colour classification with a margin check.
  - Checks the CRC and drops duplicate frames.
  - Calibrate with `dufleet calibrate bot01`.
- **Deframer:** reassembles chunks by (bot, seq) with a 10 s TTL, checks CRC, and counts corrupt frames.
- **Input injector:**
  - Before each send:
    - The window exists.
    - `SetForegroundWindow` succeeds (with the AttachThreadInput workaround).
    - A re-read of the foreground window matches the target.
    - On a shared desktop, the user has been idle for more than 2 s (`GetLastInputInfo`).
  - Sending:
    - Open chat with the configured key (Enter by default; confirm in S3).
    - Type with SendInput `KEYEVENTF_UNICODE` at about 5 ms per character, then Enter, then Esc if chat stays open.
  - Fallbacks: an AHK v2 `SendText` script, or scan-code input if the game ignores virtual keys (S4).
  - Afterwards, expect an ACK within the timeout.
  - One global input mutex per Windows session. This is why each client needs its own VM or PC.
- **Capture:** full-window PNGs for vision, region crops for optical and status templates, and a 30 s rolling buffer saved on incidents.
- **Hub:**
  - supabase-py signs in as the bot's device user.
  - Subscribes to realtime changes on `commands` filtered by `bot_id`, and also polls `queued` rows on every (re)subscribe.
  - The command pump claims rows with the `claim_next_command` RPC and updates their status.
  - Upserts `bot_state` at 1 Hz and inserts history into `telemetry` every 5 s.
- **Watchdog:**
  - States: offline → launching → login → in_world → ready → busy → degraded → crashed.
  - Detects:
    - the process is gone
    - the window hangs (`IsHungAppWindow`)
    - no heartbeat for 30 s
    - the disconnect dialog appears (template match)
    - a disconnect string shows in the log (collect these in S0)
  - Recovery: kill → relaunch → log in → return to the anchor position → reactivate the PB → `/b ping` → resume from `dub.job`.
- **Config:**
  - One `bots/<id>.toml` per bot: server, account alias, window rect, HUD scale, transport, keybinds, optical region, anchor `::pos`, allowed skills.
  - Passwords live in Windows Credential Manager via `keyring`.
- **Packaging:** a uv project built with PyInstaller (one folder), started by a Task Scheduler "at logon" task per VM. Logs rotate under `%PROGRAMDATA%\dufleet\logs`.

### 5. Supabase schema

```sql
-- 0001_core.sql
create extension if not exists pgcrypto;
create type bot_status as enum ('offline','launching','login','in_world','ready','busy','degraded','crashed');
create type cmd_status as enum ('queued','claimed','sent','acked','done','failed','failed_delivery','cancelled');
create type goal_status as enum ('pending','planning','active','blocked','done','failed','cancelled');

create table public.servers (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null, url text not null,
  automation_permitted boolean not null default false, notes text,
  created_at timestamptz not null default now());

create table public.bots (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  server_id uuid references public.servers(id),
  short_id text not null, host text,
  device_user_id uuid references auth.users(id),
  status bot_status not null default 'offline',
  script_version text, boot_id text, last_seen timestamptz,
  created_at timestamptz not null default now(),
  unique (owner_id, short_id));

create table public.bot_state (
  bot_id uuid primary key references public.bots(id) on delete cascade,
  pos_str text, wx double precision, wy double precision, wz double precision,
  body_id int, lat double precision, lon double precision, alt double precision,
  speed_kmh real, fuel jsonb, cargo_ratio real, skill text, skill_phase text,
  updated_at timestamptz not null default now());

create table public.telemetry (
  id bigint generated always as identity primary key,
  bot_id uuid not null references public.bots(id) on delete cascade,
  ts timestamptz not null default now(), data jsonb not null);
create index telemetry_bot_ts on public.telemetry (bot_id, ts desc);

create table public.command_seq (
  bot_id uuid primary key references public.bots(id) on delete cascade,
  next bigint not null default 1);

create table public.commands (
  id uuid primary key default gen_random_uuid(),
  bot_id uuid not null references public.bots(id) on delete cascade,
  cseq bigint, verb text not null, args jsonb not null default '{}',
  job_id text, goal_id uuid,
  status cmd_status not null default 'queued',
  attempts int not null default 0, error text, result jsonb,
  created_by text not null default 'user',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (bot_id, cseq));
create index commands_bot_status on public.commands (bot_id, status, cseq);

create table public.goals (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  bot_id uuid references public.bots(id),
  parent_id uuid references public.goals(id),
  title text not null, spec jsonb not null default '{}',
  status goal_status not null default 'pending', plan jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());

create table public.skills (
  name text primary key, version text not null,
  args_schema jsonb not null, description text not null,
  preconditions jsonb, postconditions jsonb,
  success_count int not null default 0, failure_count int not null default 0);

create table public.events (
  id bigint generated always as identity primary key,
  bot_id uuid references public.bots(id) on delete cascade,
  ts timestamptz not null default now(),
  kind text not null, severity smallint not null default 0, data jsonb not null);
create index events_bot_ts on public.events (bot_id, ts desc);

create or replace function public.assign_cseq() returns trigger language plpgsql as $$
begin
  insert into public.command_seq(bot_id) values (new.bot_id) on conflict do nothing;
  update public.command_seq set next = next + 1 where bot_id = new.bot_id
    returning next - 1 into new.cseq;
  return new;
end $$;
create trigger commands_cseq before insert on public.commands
  for each row when (new.cseq is null) execute function public.assign_cseq();

create or replace function public.claim_next_command(p_bot uuid) returns public.commands
language sql security invoker as $$
  update public.commands c set status='claimed', attempts=attempts+1, updated_at=now()
  where c.id = (select id from public.commands where bot_id=p_bot and status='queued'
                order by cseq limit 1 for update skip locked)
  returning c.*;
$$;
```

```sql
-- 0002_rls.sql
alter table public.servers   enable row level security;
alter table public.bots      enable row level security;
alter table public.bot_state enable row level security;
alter table public.telemetry enable row level security;
alter table public.commands  enable row level security;
alter table public.goals     enable row level security;
alter table public.events    enable row level security;
alter table public.skills    enable row level security;

create or replace function public.can_access_bot(p_bot uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from bots b where b.id = p_bot
    and (b.owner_id = auth.uid() or b.device_user_id = auth.uid()));
$$;

create policy servers_owner on public.servers for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy bots_owner on public.bots for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy bots_device_read on public.bots for select using (device_user_id = auth.uid());
create policy bots_device_update on public.bots for update using (device_user_id = auth.uid());
create policy state_rw on public.bot_state for all using (public.can_access_bot(bot_id)) with check (public.can_access_bot(bot_id));
create policy tel_rw on public.telemetry for all using (public.can_access_bot(bot_id)) with check (public.can_access_bot(bot_id));
create policy cmd_rw on public.commands for all using (public.can_access_bot(bot_id)) with check (public.can_access_bot(bot_id));
create policy ev_rw on public.events for all using (bot_id is null or public.can_access_bot(bot_id)) with check (bot_id is null or public.can_access_bot(bot_id));
create policy goals_owner on public.goals for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy skills_read on public.skills for select using (auth.role() = 'authenticated');
```

```sql
-- 0003_realtime.sql
alter publication supabase_realtime add table public.commands, public.bot_state, public.events, public.bots, public.goals;
alter table public.commands replica identity full;

-- 0004_retention.sql
create extension if not exists pg_cron;
select cron.schedule('telemetry-retention','15 * * * *',
  $$delete from public.telemetry where ts < now() - interval '7 days'$$);
select cron.schedule('events-retention','30 3 * * *',
  $$delete from public.events where ts < now() - interval '30 days' and severity < 2$$);
```

- `telemetry` is left out of the realtime publication on purpose. The UI subscribes to `bot_state` (one row per bot) instead, so realtime traffic stays flat as the fleet grows.
- Each companion signs in as its own device user, never with the service-role key, so a compromised VM can only touch its own bot.

### 6. Dashboard

- **Auth:** `@supabase/ssr` with session refresh in `middleware.ts`, and a magic link for the owner.
- **`/fleet`:** a grid of BotCards showing status, a script-version drift badge, skill/phase, speed, fuel, cargo, last-seen and incident count. Live via realtime on `bot_state` and `bots`.
- **`/bots/[id]`:**
  - live state
  - 1 h sparklines (loaded server-side, then appended live)
  - command history and events
  - incident screenshots from the Storage bucket `incidents/`
- **`/map`:**
  - `lib/du/pos.ts` parses `::pos{systemId,bodyId,lat,lon,alt}`. `bodyId` 0 means absolute world coordinates, which matches how Saga's `/convert` handles it.
  - Per-body lat/lon view, plus a system view in world XYZ using body data in `lib/du/bodies.ts`.
  - Seed `bodies.ts` from wolfe-labs/DU-OpenData or Saga's atlas, and verify it on each server, since admins can customise bodies.
- **`/commands`:**
  - The composer is generated from `packages/protocol`, with JSON-schema validation.
  - The queue shows statuses live, with cancel and retry.
- **`/goals`:** a goal tree, assignment to a bot or to the planner, a step viewer, and pause/resume.
- **`/logs`:** filter events by bot, kind and severity.
- **Style:** neutral palette, monospace numerals, dense tables, keyboard shortcuts, no emoji.

### 7. Planner

- **What carries over:**
  - The Voyager/Autonomy loop: goal → decomposition → skill calls → verification → skill library.
  - From Autonomy: the goal queue, precondition checks and retry structures. Swap the Minecraft executors for `run_skill`.
- **What changes:**
  - The LLM does not write Lua at runtime. Scripts have to be pasted into elements, and the CPU quota punishes unvetted code.
  - It only composes registered skills.
  - "Skill learning" becomes storing successful parameterised macro sequences, ranked by success rate.

**Tool schema:**

```json
[
 {"name":"run_skill","parameters":{"type":"object","required":["bot","skill","args"],
  "properties":{"bot":{"type":"string"},"skill":{"enum":["goto","mine_loop","haul_route","industry","patrol"]},
  "args":{"type":"object"},"timeout_s":{"type":"integer","default":900}}}},
 {"name":"get_state","parameters":{"type":"object","required":["bot"],"properties":{"bot":{"type":"string"}}}},
 {"name":"query_events","parameters":{"type":"object","properties":{"bot":{"type":"string"},"since_s":{"type":"integer"}}}},
 {"name":"vision_task","parameters":{"type":"object","required":["bot","instruction"],
  "properties":{"bot":{"type":"string"},"instruction":{"type":"string"},"max_steps":{"type":"integer","default":12}}}},
 {"name":"wait","parameters":{"type":"object","properties":{"seconds":{"type":"integer"}}}},
 {"name":"complete_goal","parameters":{"type":"object","required":["goal_id","summary"]}},
 {"name":"fail_goal","parameters":{"type":"object","required":["goal_id","reason"]}}
]
```

- **Loop:**
  1. Take the active goal and build context: bot state, the last 20 events, relevant memories, and the skill catalogue with pre/postconditions and success rates.
  2. Ask the LLM for the next step or a sub-goal split.
  3. Validate it against the schema and preconditions, then enqueue it.
  4. Wait for `R` or a timeout.
  5. Check postconditions in code, then write the outcome to memory.
- **Memory:**
  - episodic (goal/step/outcome)
  - semantic (named places, ore sites, markets; pgvector if needed)
  - procedural (macros)
- **Recovery:**
  - `E_BUSY` → wait or cancel.
  - `E_LINK` → mark the goal blocked, with instructions for a human.
  - `E_FUEL` → add a refuel sub-goal.
  - `failed_delivery` → the watchdog restart path.
  - `goto` running past 2× its ETA → abort and re-plan at a different altitude.
  - Retry limits: 3 per step and 10 per goal, then mark it blocked and alert.
- **Vision loop** (market, trade, login, menus):
  - Screenshot → VLM (a Claude model with vision) → structured action (`click`, `type`, `key`, `done`, `abort`) → executed through the focus-safe injector → verified with a new screenshot.
  - Limits: a step cap, a whitelist of screen regions, and an abort on any unexpected dialog.
  - Every step is logged. Trades above a set value need confirmation on the dashboard.

### 8. Phased build plan

**Phase 0: Spikes S0–S4.**
- Acceptance: ADR-0001 picks the transport, a log sample or calibration fixture is committed, and the keybinds are documented.

**Phase 1: MVP, one client.**
1. Scaffold the monorepo, the protocol schema and codegen, and the CRC vectors.
2. Lua: bus, cmd, builtin commands (`ping`, `status`, `setid`, `cal`), position/speed collectors, databank persistence. Busted tests.
3. Companion: config, window and focus handling, chat sender, the chosen ingest path, deframer, Supabase device auth, `bot_state` upsert, and the command pump with ACK/retry.
4. Migrations 0001–0004 and seed data.
5. Dashboard: login, `/fleet`, `/bots/[id]`, and `/commands` (ping/status only).

- Acceptance:
  - A dashboard ping round-trips in under 5 s, 20 out of 20 times.
  - Telemetry arrives at 1 Hz or better.
  - After the companion is killed and restarted, no command runs twice.
  - Corrupt frames are rejected.

**Phase 2: Skills.**
1. Build `SagaAdapter` and `goto` with arrival checks.
2. `haul_route`, then `industry`, then `patrol`, then `mine_loop` once S7 is done.
3. Registry rows in `skills`, and `/map`.

- Acceptance:
  - `goto` lands within 5 m of the target on 10 of 10 same-planet trips.
  - 3 unattended haul loops.
  - Cancel cuts thrust within 2 s.
  - No CPU overload errors in a 2 h soak.

**Phase 3: Fleet and relay.**
1. Watchdog relaunch and re-login, with job resume.
2. One companion per host, plus a version-drift alert.
3. The `relay` verb, a worker build, and emitter fan-out with ACKs.

- Acceptance:
  - 3 bots run for 8 h with at most 1 manual intervention.
  - A killed client is back to `ready` in under 5 minutes.
  - Relayed commands ACK 19 out of 20 times.

**Phase 4: Planner and vision.**
1. Planner loop, memory, recovery, goals UI.
2. Vision login, then read-only market reads, then gated trades.
3. Macro learning.

- Acceptance:
  - A haul goal is completed with no human input.
  - Injected failures (low fuel, missing link) end in the correct recovery or in `blocked`.
  - Vision login succeeds 9 out of 10 times.

### 9. Testing strategy

- **Lua:**
  - busted with du-mocks: `luarocks install du-mocks`, and add `../du-mocks/src/?.lua` to `LUA_PATH`.
  - Golden frame vectors shared with Python.
  - Parser fuzzing (it must never throw).
  - Dedupe tests.
  - Skill state machines driven by a fake clock.
  - A regression check on loop iterations per tick.
  - Any API missing from du-mocks (codex dated 2024-09) counts as "verify in game".
- **Companion:**
  - pytest with S0 log fixtures: partial writes, rotation, non-UTF-8 bytes.
  - Optical PNG fixtures, including JPEG-degraded and misaligned ones.
  - Golden deframer output.
  - A local `supabase start`.
  - A dummy Win32 window that echoes keystrokes, for testing the injector.
  - `dufleet replay <fixture>` for full-pipeline replays.
- **Dashboard:** Playwright smoke tests. Insert a `bot_state` row and check the card updates.
- **In-game release checklist:**
  1. Paste the build and check the slot names.
  2. Run `/b ping` and get an ACK.
  3. Confirm telemetry is flowing.
  4. Send a duplicate `cseq` and confirm it's ignored.
  5. Alt-tab mid-send and confirm the retry recovers.
  6. Confirm Saga's own commands still work.
  7. Do a short `goto` hop, then abort mid-flight.
  8. Restart the PB and confirm the job resumes.
  9. Kill the client and confirm the watchdog restarts it.
  10. Relay to a worker at 50 m, 500 m and maximum range.

### 10. Spikes, risks, hardware

| ID | Question | Blocks |
|---|---|---|
| S0 | Does `system.print` reach the disk log? Latency, max line length, escaping, file naming and rotation. Are the `io`/`os` globals absent? | Everything |
| S1 | Is the optical HUD grid legible at the pinned resolution? What redraw rate is possible, and what does it cost in CPU? | Transport O |
| S2 | Does `onInputText` fire on every running unit? Does it coexist with Saga's handler? | Routing |
| S3 | Chat open key, tab persistence, max input length, behaviour when a menu is open | Injector |
| S4 | Unicode SendInput vs scan codes | Injector |
| S5 | Emitter range, size and rate limits; the direct-link requirement | Phase 3 |
| S6 | PB proximity radius; the detection-zone reactivation trick | Phase 3 |
| S7 | Which mining/calibration actions Lua can reach vs UI-only | mine_loop |
| S8 | Automating login; whether an anti-cheat component is present; per-client resource use | Watchdog, sizing |
| S9 | The admin's written automation policy, including the optical channel | Go-live |

**Risks:**
1. **No log channel.** Transport O is built in from the start.
2. **Policy.** NQ removed log output specifically to stop bots. Stay client-side, touch nothing outside `Game/data/lua`, and get admin consent in writing.
3. **Focus contention.** Mitigated by one client per VM or PC, the input mutex, and checks after every send.
4. **CPU overload from Saga plus the bus together.** Mitigated by timers, round-robin collectors and soak tests.
5. **Drift in the Saga fork.** Keep it a thin subtree and rebase when upstream releases.
6. **Client updates.** Fixtures plus `dufleet doctor` at startup.

**Hardware (unverified estimates; measure in S8):**
- Per client: Windows 10/11, AVX, about 4 cores, 8–12 GB RAM, a GPU at low settings, 1280×720 with a frame cap, and roughly 30–60 GB of disk.
- Options, in order:
  1. Spare PCs (most reliable).
  2. Hyper-V GPU-P VMs on one workstation, each VM with its own foreground window.
  3. Cloud GPU instances (expensive for 24/7).
- Start with one host plus one VM.

### 11. CLAUDE.md

```markdown
# CLAUDE.md — mydu-fleet

## What this is
Client-side automation for myDU (self-hosted Dual Universe) on servers whose admins permit automation.
No server mods, no DB/backoffice access. One real game client per bot (Windows 10/11, AVX).
Lua (in-game) <-> Python companion (per client host) <-> Supabase hub <-> Next.js dashboard; Python LLM planner.

## Hard facts (do not re-litigate)
- system.logInfo/logWarning/logError were REMOVED from DU Lua (Panacea, 2022). Never use them.
- Whether system.print reaches the disk log is decided by spike S0 (docs/spikes.md, ADR-0001).
  Protocol is transport-agnostic: Transport L (log tail) or Transport O (optical HUD grid).
- Commands in = chat lines "/b <cseq> <verb> ... #<crc16>" handled via system.onInputText.
- Lua sandbox: no HTTP, no file IO (confirm in S0). Never do bot work in onUpdate/onFlush; use a 0.25 s timer.
- Flight = vendored fork of tobitege/du-saga (GPL-3.0) under lua/vendor/saga; our code calls SagaAdapter.
- Never modify game files outside Game/data/lua; never read/modify client memory.

## Stack and conventions
- lua/: DU-LuaC, cli.fmtVersion 2, events via obj:onEvent('onX', fn), links via library.getLinksByClass.
  Tests: busted + du-mocks. Databank keys prefixed "dub.". Production target minified.
- companion/: Python 3.12, uv, pydantic, asyncio, pytest. Win32 code isolated in proc/ and inject/.
  All input via inject/focus.py (verify foreground HWND before/after). One global input mutex.
- supabase/: SQL migrations only. RLS on every table. Companion = device user, never service role.
- dashboard/: Next.js App Router, server components by default, @supabase/ssr, Tailwind, no emoji, dense tables.
- packages/protocol/: single source of truth (protocol.schema.json, vectors.json); regenerate constants, never hand-edit.
- Conventional commits. Protocol changes bump docs/protocol.md and vectors.json.

## Current phase: 0/1
1. Scaffold monorepo; packages/protocol with envelope + grammar schema and CRC-16/CCITT-FALSE vectors.
2. lua/: bus/frame, bus/outbox, cmd/parser, cmd/dispatcher, cmd/builtin (ping,status,setid,cal),
   telemetry/collectors (pos,speed), persist/db; transport_log + transport_optical behind ---@if. busted specs.
3. companion/: config (bots/*.toml), proc/window, inject/focus + sender_sendinput + chat,
   ingest/log_tailer (newest *.xml under %LOCALAPPDATA%\NQ\DualUniverse, utf-8 errors=replace, rotation),
   ingest/optical (fiducials, 48x24 2-bit grid, CRC), deframer, hub (device auth, bot_state upsert,
   claim_next_command RPC, ack timeout 3s/5s, retries 1/3/8s). CLI: run, calibrate, replay, doctor.
4. supabase/migrations 0001_core, 0002_rls, 0003_realtime, 0004_retention; seed.sql.
5. dashboard/: login, /fleet (realtime bot_state), /bots/[id], /commands (ping/status).
Acceptance: ping round-trip <5s 20/20; 1 Hz telemetry; no duplicate execution after companion restart; corrupt frames rejected.

## When unsure
- DU API behavior not in the du-mocks codex: add a spike to docs/spikes.md; do not guess.
- Small testable modules; a fixture for every parser.
```

## Recommendations

1. **Run S0 before writing any code.** It takes about 15 minutes: one PB prints a nonce every second while you grep the newest XML log. The result decides whether the optical channel becomes the backbone.
2. **Get written automation consent from each myDU admin**, covering screen-read telemetry too, and record it in `servers.automation_permitted`.
3. **Fork Saga and call its `/goto` pipeline in-process.** Keep chat for the `/b` channel only.
4. **Keep the LLM out of Lua generation.** The planner only composes vetted skills.
5. **If an admin ever cooperates, move to the myDU server-mod client API.** It removes the focus and OCR fragility, and the hub, dashboard and planner carry over unchanged.

## Caveats

- **Unverified, all on the spike list:**
  - whether `system.print` output is written to disk
  - the XML record schema, log subfolder and file naming
  - chat keybinds and length limit
  - CPU quota numbers
  - emitter limits
  - the ~35 m PB proximity radius (a community report)
  - whether the myDU client includes EQU8
  - du-socket internals
  - the contents of the tobitege/du-tools README
  - the hardware figures
- The Panacea quotes come from forum search snippets and MassivelyOP, because the NQ forum blocks automated fetching. They agree with each other and with every deprecated log-tool README.
- The du-mocks codex dates from September 2024, and the myDU client API may differ from it.
- The emitter relay quirk comes from a single 2023 forum report.