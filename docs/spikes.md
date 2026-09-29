# Spike results

What the Phase 0 spikes measured. The questions and their order are in [plan.md](plan.md#phase-0-spikes). One in-game session with the [probe kit](../spikes/README.md) answers most of them. Claude fills this page in from `spikes/results/summary.md` and your notes, and [ADR-0001](adr/0001-transports.md) cites it.

Session 1 ran on 2026-09-28 on the owner's PC: Windows 11, one 2560×1600 monitor, on The Third Verse, with ArchHUD 2.105 at the pinned commit, the server's atlas and probe 0.1.1. Its optical and inbox results are kept in [spikes/fixtures/2026-09-28/](../spikes/fixtures/2026-09-28/).

| ID | Status | Result |
|---|---|---|
| S9 | Granted for tests | The owners of The Third Verse and Settlers permit tests on their servers. Whether that also covers bots running unattended is not recorded yet. Source: the project owner, 2026-09-28 |
| S8 | Done | Paths found, no EQU8 traces. The install needed a one-time permission change |
| A1 | Pass, same planet | ArchHUD landed 11.5 m from a target about 2 km away |
| A2 | Pass, after a fix | The hook works. The first run crashed ArchHUD's startup: required files cannot see `system` or `unit` |
| S11 | Pass | A re-`require` reads the rewritten file within 0.6 s, for 37 instructions |
| S0 | Fail | No `system.print` line reaches the log. Transport L is out |
| S1 | Pass | 2,391 captures decoded with no cell errors, at 6 px and 2 fps and at 4 px and 4 fps |
| S3 | Mostly failed | Only 2 of 9 typed lines reached the Lua chat |
| S4 | Unclear | Same run: which of the unicode, scan code and virtual key modes delivered is unknown |
| S10 | Pass, short run | At most about 12% of the 1,000,000-instruction limit |
| S12 | Not run | Does the bus reach the unit and core through ArchHUD's `Nav`, and the databank through ArchHUD's class constructors? Step 12 answers it: an `H` frame arrives, and no `D` frame says "no databank" |
| S5, S6, S7 | Later: Phase 3 and `mine_loop` | |

A question about DU behaviour that neither the Codex nor du-mocks answers gets a new row here, with an ID, before any code relies on an answer.

## Session 1 details

### S8: paths, processes, install

- Lua folder: `C:\ProgramData\My Dual Universe\Game\data\lua`.
- Logs: `%LOCALAPPDATA%\NQ\myDU\log\log_<date>_<time>.xml`, a new file for every client start. While ArchHUD flies, the log grows by about 1.3 MB per minute (see S0).
- `Game\Bin\Dual.exe` runs unelevated and used 5.1–5.9 GB of memory.
- EQU8: no processes, services or driver files.
- Files that came into `autoconf\custom\` through a UAC prompt belong to Administrators. A user may add files next to them but not replace them. The install needed Modify rights for the owner's account, granted once from an administrator terminal: `icacls "<Lua folder>\autoconf\custom" /grant "<user>:(OI)(CI)M"`. The installer now checks this before it writes.
- Not measured: login automation, GPU use per client, the FPS cap.

### A1: ArchHUD flies on The Third Verse

- Pilot seat, databank cleared, ArchHUD 2.105 with the server's atlas.
- A trip of about 2 km on Alioth, to a `::pos` pasted into chat. It flew the way ArchHUD always does; the owner finds the profile odd for so short a hop.
- Target `::pos{0,2,39.7103,104.8594,-0.0000}`, a map point at sea level. The ship stopped at `::pos{0,2,39.7115,104.8660,115.2805}`, on the ground: 11.5 m from the target (2.6 m north, 11.2 m east), computed with Alioth's radius from the atlas (126,067.9 m). The stop position is the seated player's, so the ship's centre can differ by the seat's offset.
- Not tried: a remote controller, a trip to another planet.

### A2: the `userclass` hook

- The first run printed `ERROR STARTUP: [string "-- dufleet probe ..."]:93: attempt to index a nil value (global 'system')`, and ArchHUD's HUD did not appear. Files loaded with `require` cannot see the handler slots `system` and `unit`. The probe's error handler also called `system.print`, so the error escaped its `pcall` into ArchHUD's startup.
- Probe 0.1.1 uses `DUSystem`, takes the unit from `script.onTick(timerId, unit)`, and its shim runs every hook under `pcall` ([verification.md](verification.md#addendum-in-game-2026-09-28)).
- With 0.1.1:
  - `ExtraOnStart` fires.
  - `/b` lines reach the probe before ArchHUD: `/b ping ::pos{...}` made no waypoint.
  - `/commands` and other lines still reach ArchHUD.
  - The `dub` timer ticks through the wrapped `PROGRAM.onTick`.
  - `userScreen` content (the panel and the optical frame) shows.
  - No errors in 62 minutes.
- The 0.25 s timer ran at 3.78 ticks per second (14,155 ticks in 3,743 s): a tick waits for the next rendered frame.

### S11: file inbox

- Available: `package` (with `loaded` and `preload`), `require`, `load`, `loadfile`, `dofile` and `debug`. Missing: `io`, `os`, `loadstring`. `_VERSION` is "Lua 5.4".
- Clearing `package.loaded[name]` and calling `require` again reads the file as it is now.
  - The companion wrote 180 versions, one per second, each time as a temp file renamed over the old one. No rename had to be retried.
  - Polling every 0.5 s, the probe saw 179 changes, ending at seq 180.
  - From write to read took 0.12–0.57 s. One read costs 37 instructions.
- The client logs the first load of every file at unit start ("Found ung override for lua load of lua/autoconf/custom/...") but not these re-reads.

### S0: log channel

- No probe line reached the log in 480 s: 29,721 records, 0 probe lines. Meanwhile the probe printed heartbeats, the length sweep (`/b len`) and the escape line (`/b esc`). Transport L is out.
- The log is mostly `Executing a Lua method in the wrong thread. method='setAxisCommandValue', inFlush=true, method is Flush compatible:false, method is Update compatible:true`, about 60 per second from ArchHUD's flush. The owner's logs from February 2026, with other ArchHUD builds, show the same warnings.

### S1: optical frame

- The 48×24 test frame at 2 bits per cell, drawn through `userScreen` on the 2560×1600 screen. HUD pixels map one to one onto screen pixels (a 6 px cell measured 6.00 px).
- 6 px cells at 2 frames per second: 1,195 of 1,195 captures decoded, 227 frames, no cell errors, no missed frames.
- 4 px cells at 4 frames per second: 1,196 of 1,196 captures, 454 frames (3.78 per second, the timer's real rate), no cell errors, no missed frames.
- Decoding takes about 1.1 ms per capture. Building one frame costs 52,000–54,000 instructions in the game.
- The frame partly covered ArchHUD's own text; decoding was not affected. Each run lasted 2 minutes, parked, with the game in front. The 1-bit mode was not tried.

### S3 and S4: typing into chat

- `inject` in unicode, scan code and virtual key modes, 3 lines each (`/b ping N`, 9 characters), with Enter as the open key. Each line took 0.06–0.07 s to type, into an unelevated client from an unelevated terminal.
- Only 2 of the 9 lines arrived: the panel's "/b lines" went from 17 to 19, the last a 9-character `ping`. "passed to ArchHUD" stayed at 5, so the other 7 never reached the Lua chat. Which modes delivered, and where the other keystrokes went, is unknown. Keep the ship parked with the brake on during injector tests.
- Next time: one mode at a time, slower typing, and a check of the panel after each line.
- Not run: the length sweep, menus, tab persistence. Chat is no longer the command path ([ADR-0001](adr/0001-transports.md)); these matter for login and UI work.

### S10: instruction headroom

- `getInstructionLimit()` is 1,000,000.
- Highest counts in 62 minutes, which included the A1 flight, with the frame at 4 fps and the inbox polled every 0.5 s:

  | Measure | Instructions |
  |---|---|
  | Already used when the probe's tick started | 70,078 |
  | Used by the probe's tick itself, mostly the frame | 54,211 |
  | At the end of ArchHUD's flush | 51,830 |
  | At the end of ArchHUD's update | 1,026 |

- The worst case is about 12% of the limit. The 2 h soak (Phase 2 acceptance) is still to do.
