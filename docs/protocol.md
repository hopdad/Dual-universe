# Bot bus protocol, version 1

The wire protocol between the in-game bus (Lua, inside ArchHUD's control unit) and the companion (Python, on the same PC). It replaces handoff §2 wherever the two differ.

Sources of truth, in `packages/protocol/`:

| File | Role |
|---|---|
| `protocol.schema.json` | Constants, kinds, error codes, verbs and argument types (`x-protocol`), and a JSON Schema for every frame body (`$defs`) |
| `skills.json` | The skills the bus implements: each one's parameters as JSON Schema, pre and postconditions, and examples that the Lua and Python tests both check |
| `codegen.py` | Writes `lua/autoconf/custom/dufleet/protocol_gen.lua`, `companion/src/dufleet/protocol/generated.py`, `dashboard/lib/protocol.ts` and the hub's skills rows (`supabase/seed/skills.sql`). `--check` fails in CI if any is stale. Never edit the generated files |
| `tools/make_vectors.py` | Writes `vectors.json` from the Python reference codec (`companion/src/dufleet/protocol/`) |
| `vectors.json` | The contract. The Lua and Python tests both run against it |

To change the protocol, edit the schema or the codec, run both generators, review the diff of `vectors.json`, and update this document. A change that old bus code would misread bumps `version`.

## Directions and transports

| Direction | Unit | Transport (ADR-0001 pending) |
|---|---|---|
| Bus to companion | Frames: one line each | L, the client log, if `system.print` reaches it (S0). O, an optical grid drawn through ArchHUD's `userScreen`, otherwise |
| Companion to bus | Commands: one line each | F, a local inbox file the bus re-reads, if S11 passes. C, chat lines typed into the Lua chat, otherwise |

The formats below are the same on every transport. Transport O carries the same lines inside its grid frames.

## Frames (bus to companion)

```
@@DUB|1|<bot>|<kind>|<seq>|<i>/<n>|<crc16>|<body>
```

| Field | Rule |
|---|---|
| `1` | Protocol version. The companion drops other versions |
| `bot` | `[A-Za-z0-9_-]{1,16}`, set with `setid` and kept in the databank. Until then, `c` plus the construct id |
| `kind` | One of `H T E A N R D` (below) |
| `seq` | Counter per bus start, from 1, at most 2^32-1, no leading zeros. Frames sent again by `resend` keep their seq |
| `i/n` | Chunk index and count, 1 ≤ i ≤ n ≤ 99, no leading zeros |
| `crc16` | CRC-16/CCITT-FALSE of this line's body bytes, 4 uppercase hex digits. Check value: `123456789` gives `29B1` |
| `body` | Compact JSON object, or a base64 chunk of one |

Framing:
- `maxline` counts UTF-8 bytes, not characters. The default is 400 until S0 or S1 measures it.
- A body goes on one line (`1/1`) when the whole line fits in `maxline`. Otherwise its UTF-8 bytes are base64-encoded (standard alphabet, padded) and split into `n` chunks of equal size, the last one shorter. `n` is the smallest count ≥ 2 for which every line fits, with each header sized as if its index had as many digits as `n`. If a chunk would hold fewer than 16 characters, or `n` would exceed 99, the frame is refused.
- Parsers find `@@DUB|` anywhere in the line (a log prefix may precede it), strip a trailing CR/LF, and split on `|` at most 7 times. The body may contain `|`.
- The companion reassembles chunks by (bot, kind, seq, n) within 10 s, then decodes the base64 and the JSON. Anything that fails is dropped and counted by reason.
- A chunk identical to one of a message delivered in the last 10 s is a duplicate and is ignored. Transport O sees each frame several times. When an H frame shows a new boot id, the companion drops that bot's partial messages.

### Kinds and bodies

JSON Schemas for every body are in `protocol.schema.json` under `$defs`. Unknown fields are refused, except inside `T.x`, `E.data`, `A.data` and `R.data`.

| Kind | Body | Required fields | Priority | Replay ring |
|---|---|---|---|---|
| `A` ack | `ack` | `ref` (cseq), `e` (epoch). Optional `dup`, `job`, `data` | 0 | yes |
| `N` nack | `nack` | `ref`, `e`, `err`. Optional `msg` (≤ 120 chars), `dup` | 0 | yes |
| `E` event | `event` | `ev` (`[a-z][a-z0-9_]{0,31}`). Optional `job`, `skill`, `from`, `to`, `data` | 1 | yes |
| `R` result | `result` | `job`, `skill`, `ok`. Optional `data`, `err`, `msg` | 1 | yes |
| `H` hello | `hello` | `boot`, `v` (bus semver), `epoch`, `cseq`. Optional `id`, `ah` (ArchHUD commit), `tr`, `ml`, `q` | 1 | no |
| `T` telemetry | `telemetry` | none. `w`, `v`, `alt`, `b`, `g`, `fuel`, `cargo`, `st`, `job`, `ap`, `x` | 2 | no |
| `D` debug | `debug` | `msg` (≤ 300 chars) | 3 | no |

Examples:

```
{"ref":42,"e":1,"job":"j_7a1"}
{"ref":43,"e":1,"err":"E_BUSY","msg":"skill goto running"}
{"ev":"skill_state","skill":"goto","from":"align","to":"travel","job":"j_7a1"}
{"job":"j_7a1","skill":"goto","ok":true,"data":{"dist":3.2,"t":184}}
{"boot":"k3f9a1","v":"0.1.0","epoch":1,"cseq":42,"id":"hauler-1","ah":"6c95222","tr":"O","ml":400,"q":0}
{"w":[-123456.5,98765.25,42.0],"v":12.4,"alt":285.5,"b":2,"g":[35.3951,104.1187],"fuel":{"atmo":0.82},"cargo":0.41,"st":"goto:travel","ap":"altitude_hold"}
```

Positions are world coordinates in metres (`w`) plus latitude and longitude (`g`) on body `b`. A `::pos{...}` string never appears in a frame or a command.

### Outbox rules (bus)

- Lower priority numbers go first. Within a priority, frames go in the order they were queued. A frame gets its seq when it starts to go out, so seqs follow send order, and a chunked frame finishes before the next one starts.
- Only the newest `T` waits in the outbox; a new one replaces it.
- `A`, `N`, `E` and `R` frames also go into a ring of the last 32, which `resend` replays with their original seq.
- `H` goes out at bus start, after `status`, and every 30 s.
- How many lines go out per tick depends on the transport (ADR-0001).

## Commands (companion to bus)

```
/b <epoch>.<cseq> <verb> [args...] #<crc16>
```

- `epoch` (1 to 65535) and `cseq` (1 to 2^31-1) come from the hub: `cseq` is assigned by the database per bot, and `epoch` changes whenever that sequence restarts. No leading zeros.
- The CRC is CRC-16/CCITT-FALSE over the bytes between `/b ` and ` #`, as 4 uppercase hex digits.
- A line is at most 240 characters of printable ASCII (0x20 to 0x7E) without `"` or `\`. Tokens are separated by single spaces. The only `#` is the one before the CRC.
- The text `::pos` is refused anywhere in the line: ArchHUD turns any chat line containing it into a waypoint. Write positions as `pos=<systemId>,<bodyId>,<lat>,<lon>,<alt>`.
- Argument values cannot contain spaces.

### Checks, in order

The bus and the companion's validator apply the same checks in the same order, so a line gets the same answer on both sides (`vectors.json`, `command_errors`).

| Order | Error | Checks | `ref` and `e` in the N frame |
|---|---|---|---|
| 1 | `E_PARSE` | Prefix, length, characters, ` #XXXX` suffix, no other `#`, no `::pos`, spacing, header syntax and range | 0 and 0 |
| 2 | `E_CRC` | The CRC matches | from the header |
| 3 | `E_VERB` | The verb is `[a-z]+` and in the table below | from the header |
| 4 | `E_ARGS` | The arguments fit the verb | from the header |
| 5 | `E_EPOCH`, `E_STATE` | Dedupe (below) | from the header |
| 6 | `E_BUSY`, `E_STATE`, `E_LINK`, `E_FUEL`, `E_INTERNAL` | The verb's handler | from the header |

Checks 1 to 4 never change bus state. Only a command that reaches its handler moves the watermark.

### Verbs

| Verb | Arguments | Effect |
|---|---|---|
| `ping` | none | Acknowledge only |
| `status` | none | Acknowledge, then send `H` and `T` |
| `cancel` | `[job]` | Stop the ship and end the running job ([Jobs](#jobs)) |
| `pause` | none | Stop the ship and hold the running job |
| `resume` | none | Continue a paused job |
| `setid` | `id` (bot) | Store the bot id in the databank |
| `resend` | `from` (uint) | Send the replay-ring frames with seq ≥ `from` again |
| `run` | `skill job [key=value ...]` | Start a skill job. Skills: `goto`, `haul_route`, `industry`, `patrol`, `mine_loop`; only `goto` exists yet |
| `db` | `get\|set\|del key [value]` | Read, write or delete one `dub.` key. Only `set` takes a value |
| `cal` | `on\|off` | Optical calibration pattern (Transport O) |
| `relay` | `chan payload` | Phase 3: forward a base64 payload to a worker board over the emitter |

Argument types (regular expressions over the whole token):

| Type | Pattern |
|---|---|
| `uint` | `0\|[1-9][0-9]{0,9}` |
| `bot` | `[A-Za-z0-9_-]{1,16}` |
| `job` | `j_[A-Za-z0-9]{1,16}` |
| `dbkey` | `dub\.[a-z0-9_.]{1,40}` |
| `kv` | `[a-z][a-z0-9_]{0,15}=V{1,120}`, where `V` is any printable character except space, `"`, `#` and `\`. Keys may not repeat |
| `text` | `V{1,200}` |
| `chan` | `V{1,64}`: the emitter drops channels over 64 characters |
| `b64` | `[A-Za-z0-9+/]+={0,2}` |

### Delivery, dedupe and epochs

- The hub hands the companion one command per bot at a time (`claim_next_command`). The companion sends it and waits for an `A` or `N` with the same `ref` and `e`: 3 s on transports L, F and C, 5 s on O. It retries after 1, 3 and 8 s, then marks the command `failed_delivery`.
- An `N` with `ref` 0 (`E_PARSE`) means the line arrived damaged. The companion treats it as a failed attempt at the command in flight and retries.
- The bus keeps its watermark in one databank key, written in a single call after the handler returns: `dub.last` = `<epoch>|<cseq>|<A or N>|<reply body JSON>`. It starts as epoch 0, cseq 0 and no reply.

For a command with a valid CRC, verb and arguments, compared with the watermark (`last_e`, `last_c`):

| Case | Outcome | Bus action |
|---|---|---|
| `e > last_e`, or `e == last_e` and `cseq > last_c` | execute | Run the handler, persist `dub.last`, send its `A` or `N`. Gaps in cseq are fine |
| `e == last_e` and `cseq == last_c` | replay | Do not run it again. Send the stored reply as a new frame with `"dup":true` |
| `e == last_e` and `cseq < last_c` | superseded | `N` `E_STATE` |
| `e < last_e` | stale | `N` `E_EPOCH` |

The companion sends one command at a time and only moves on after a reply, so a retry of the last command is always a replay and never runs twice, even if the companion restarts mid-command (`recover_inflight` resends it). A handler refusal (`E_BUSY` and so on) also moves the watermark, so a retry gets the same refusal back.

The companion passes the `epoch` and `cseq` of every H frame to the hub (`sync_epoch`). If the bot is ahead of the hub, which happens only after the hub lost its numbering (a reset or a restore), the hub moves to a new epoch and cancels its queued commands from the old one. The first command of the new epoch runs even though its cseq is low. See [supabase/README.md](../supabase/README.md).

### Jobs

A `run` starts a job. The bus runs one at a time, and the job reports back on its own:

- The skill checks its parameters before the bus replies. The reply is one of:
  - `A` with the job id: `{"ref":42,"e":1,"job":"j_7a1"}`;
  - `N` `E_BUSY` while another job runs (`"skill goto running"`);
  - `N` `E_STATE` for a skill that does not exist yet, or a state that rules the job out;
  - `N` `E_ARGS` for a missing, bad or unknown parameter.
- While the job runs:
  - each phase change sends `E` `{"ev":"skill_state","job":…,"skill":…,"from":…,"to":…}`, the first from `idle`;
  - `T.st` reads `<skill>:<phase>`.
- While the job runs, `T.job` holds its id.
- The job ends with one `R`:
  - `ok: true` with the skill's `data`;
  - or `ok: false` with `err`, `msg`, and sometimes `data`.
  - The companion keeps the `run` command `acked` until the `R` arrives, then finishes it with the result.
- An `R` lost in transit is recovered like this:
  - Once `T` frames have stopped naming the job for 10 s, the companion knows the job ended.
  - It has the hub queue `resend <seq after the run's A>` (`request_resend`, the one command a device may queue). The bus's replay ring still holds the `R`, so it comes back.
  - If the `R` has not come 30 s later, the companion fails the command with `E_STATE` `"result lost"`.
  - After a restart of either side, the resend starts from seq 0.
- `cancel [job]`:
  - stops the ship and ends the job with `R` `E_STATE` `"cancelled"`;
  - with no job running, it still stops the ship and answers `{"data":{"idle":true}}`;
  - naming a job that is not running gets `N` `E_STATE`.
- `pause` stops the ship and holds the job: `to` and `T.st` show `paused`. `resume` continues the job in the skill's first phase. Both answer `A` when the job is already in that state. Time spent paused does not count toward a timeout.
- If a skill raises an error, the bus tries to stop the ship and ends the job with `E_INTERNAL`.
- `dub.job` holds the running job as JSON (`job`, `skill`, `args`, `phase`, `paused`).
  - If the bus finds it at start, a restart cut the job off.
  - The bus then sends `R` `E_STATE` `"interrupted by a restart"` after its first `H`, and deletes the key.
  - The Phase 3 watchdog will resume such jobs instead.

"Stop the ship" means what a pilot does in ArchHUD: `AP.clearAll()`, throttle to 0, and the brake unless it is already set.

#### `goto`

Flies to a position with ArchHUD's autopilot, the way a pilot does with a `::pos` waypoint and one autopilot toggle. Its parameters, bounds and defaults come from `skills.json`, which the hub's `skills` table and the planner share.

```
run goto <job> pos=<systemId>,<bodyId>,<lat>,<lon>,<alt> [tol=<m>] [timeout=<s>]
```

| Parameter | Meaning |
|---|---|
| `pos` | As ArchHUD reads `::pos`: degrees, and metres above sea level. Body 0 is deep space, with world x, y and z in place of lat, lon and alt |
| `tol` | Arrival tolerance in metres, 1 to 100000. Default 50 on a planet and 1000 in space, until spike A1 measures ArchHUD's precision |
| `timeout` | Seconds of running time before the job gives up, 10 to 86400. Default 3600 |

| Phase | Meaning |
|---|---|
| `engage` | Selects the target as the temporary ArchHUD location `dub-<job>` and toggles the autopilot once, at least 2 s after the bus's previous toggle (two within 1.5 s in atmosphere make an orbital hop) |
| `travel` | ArchHUD is flying, launching, orbiting or landing |
| `settle` | No travel mode is set; the bus waits for the ship to stay under 1 km/h for 5 s |

How a `goto` ends:
- Done when the ship settles within `tol` of the target, with `data` `dist` (metres) and `t` (seconds running). The distance is horizontal when the target is on a planet, because ArchHUD lands under it. In space it is a straight line, because ArchHUD stops near the target.
- Refused at `run` (`E_STATE`) when:
  - ArchHUD is still starting;
  - a travel mode is set;
  - an ArchHUD route is loaded (the autopilot would fly the route instead);
  - the body is not in ArchHUD's atlas.
- Refused at `run` with `E_FUEL` (`"atmo fuel 3%, under the 10% minimum"`) when a fuel type the trip needs is below `dub.cfg.minfuel`:
  - atmospheric fuel while the ship is in atmosphere;
  - space fuel while it is in space, or when the target is on another body or in deep space.

  Fuel types the ship has no tanks for are not checked.
- Failed with `E_STATE`, each after the bus stops the ship:
  - `"stopped N m from the target"`, with `data.dist`;
  - `"autopilot off and still moving, N m from the target"`: 30 s without a travel mode;
  - `"timed out after N s"`.
- Also failed with `E_STATE` when ArchHUD refuses the target or does not engage. The bus does not stop the ship in that case.

### Databank keys

The bus writes only `dub.`-prefixed keys in ArchHUD's `dbHud_1`, which ArchHUD never clears.

| Key | Contents |
|---|---|
| `dub.schema` | Version of this key layout (1) |
| `dub.id` | Bot id |
| `dub.last` | Watermark and last reply (above) |
| `dub.job` | The running job as JSON: `job`, `skill`, `args` (its parameters), `phase`, `paused` ([Jobs](#jobs)) |
| `dub.cfg.<name>` | Bus settings, read at start: `tick` (0.25 s), `maxline` (400), `lines` per tick (2), `telemetry` period (1 s), `minfuel` for a `goto` to start (0.1; 0 turns the check off) |
| `dub.*` | Anything written with `db set` |

### Transport F inbox (provisional, pending S11)

The companion writes `autoconf/custom/dufleet/inbox.lua` atomically (a temp file, then a rename):

```lua
return { v = 1, n = 17, lines = { "/b 1.42 ping #A5F2" } }
```

`lines` are ordinary command lines, so they get the same parser, CRC and dedupe as chat. `n` goes up on every write. The bus re-requires the module on its timer and handles the lines only when `n` changes, so a retry is a new `n` with the same line.

## Changelog

| Version | Date | Change |
|---|---|---|
| 1 | 2026-09-28 | `T.job`, and recovery of an `R` lost in transit through `resend`. Additive: the frames are otherwise unchanged |
| 1 | 2026-09-27 | Jobs: the job verbs, `skill_state` events, `R`, `dub.job`, and the `goto` skill. The wire format is unchanged. `cancel` now stops the ship even with no job running |
| 1 | 2026-09-27 | First version. Against handoff §2: a bounded split, the CRC scope, an epoch in the command header, one watermark key, `chan` and `b64` argument types, `::pos` refused, `maxline` in bytes, duplicate suppression |
