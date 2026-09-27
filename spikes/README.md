# Phase 0 probe kit

One in-game session answers the open Phase 0 questions in [docs/plan.md](../docs/plan.md):

| Spike | Question | How the kit answers it |
|---|---|---|
| S8 | Where are the Lua folder and the logs? Is anti-cheat present? | `dufleet-probe paths` |
| A1 | Does ArchHUD 2.105 fly on The Third Verse? | You fly one autopilot trip |
| A2 | Does our hook in ArchHUD work? | The probe's panel and a few `/b` commands |
| S0 | Do Lua chat lines reach the disk log? | `dufleet-probe logwatch` plus `/b len` and `/b esc` |
| S11 | Can the companion hand Lua a command through a file? | `dufleet-probe inbox` plus the panel |
| S1 | Can a picture on the HUD carry data? | `/b frame on` plus `dufleet-probe optical` |
| S3, S4 | Can the companion type into the Lua chat? | `dufleet-probe inject` plus the panel |
| S10 | How much CPU budget is left next to ArchHUD? | The panel's S10 line and `/b stats` |

The kit has two halves:
- `lua/`: files that go into the game's `data\lua` folder. They are a small shim, `archhud/userclass.lua`, which ArchHUD loads by design, and the probe itself in `dufleet/`.
- `host/`: a Python command line, `dufleet-probe`, that runs on the same PC as the game.

## Before you start

- **S9 comes first.** Only run this on a server whose admin agreed to client-side automation tests, including screen capture and typing into chat. Ask The Third Verse's admins before you run it there.
- Use a test ship parked on the ground in a safe zone. ArchHUD's autopilot flies for real.
- You need:
  - a Windows 10/11 PC with the myDU client;
  - Python 3.10 or later and [uv](https://docs.astral.sh/uv/) (`winget install astral-sh.uv`);
  - this repository.
- Nothing here touches game files outside `data\lua\autoconf\custom`. Files the installer replaces are backed up first, and step 11 removes the probe again.

## Setup

In a terminal, from the repository folder:

```
cd spikes\host
uv sync
uv run dufleet-probe paths
```

`paths` finds the game's Lua folder and log folder, lists the game's processes, and looks for EQU8 traces. If it can't find the Lua folder, pass it yourself, for example `--lua-dir "C:\ProgramData\My Dual Universe\Game\data\lua"`. That is **S8**; the report is in `spikes\results\s8_paths.json`.

## The session

### 1. Install ArchHUD, the atlas and the probe

```
uv run dufleet-probe install --archhud fetch --atlas fetch --probe
uv run dufleet-probe install --archhud fetch --atlas fetch --probe --apply
```

- The first command is a dry run and only lists what would change. The second one writes.
- `fetch` downloads The-Third-Verse/ArchHUD 2.105 (commit `6c95222`) and The Third Verse's `atlas.lua` (commit `48dd00f`). The installer refuses them if their SHA-256 doesn't match the pins.
- If `paths` already said "11/11 files match" and "atlas: pinned", you only need `--probe`.
- If you already had your own `archhud\userclass.lua`, it goes to `autoconf\custom\_dufleet_backup\`, and step 11 puts it back.

### 2. Start ArchHUD with the probe (A1, A2)

1. On the test ship, link the pilot seat or remote controller as ArchHUD's manual describes (at least the core and a databank).
2. Right-click it, then Advanced, then **Run custom autoconfigure**, then **ArchHUD**. Sit down or activate it.
3. Check:
   - ArchHUD's HUD appears;
   - a green-on-black **probe panel** appears near the left edge;
   - the Lua chat tab shows `@@DUB|probe|hello|...`.

Copy the `hello` line; it lists which Lua functions the game allows. If the panel is missing, look for `dufleet` or `Error:` lines in the Lua chat.

### 3. Fly one trip (A1)

1. Get the `::pos{...}` of a spot 1 to 2 km away on the same planet.
2. Paste it into the Lua chat. ArchHUD answers "Location saved as 0-Temp".
3. Press **Alt+4**. ArchHUD's autopilot should fly there and land.
4. Note how far from the target it stopped.

A trip to another planet is a bonus.

### 4. Check the hook (A2)

Type these in the Lua chat tab:

| Type | Expect |
|---|---|
| `/b ping` | A `@@DUB|probe|pong|...` line; the panel's "/b lines" goes up |
| `/b ping ::pos{0,2,35.3951,104.1187,285.5413}` | A pong, and **no** "Location saved as 0-Temp". This proves the probe sees `/b` lines before ArchHUD |
| `/commands` | ArchHUD's own help still prints; "passed to ArchHUD" goes up |
| `/b help` | The probe's command list |

The panel's "ticks" should climb about four per second.

### 5. Log channel (S0)

In the terminal:

```
uv run dufleet-probe logwatch --duration 300
```

Then in the game, type `/b len`, and a few seconds later `/b esc`. The probe also prints a heartbeat line every 2 s for its first 5 minutes; `/b beat on` restarts them.

- If any probe line reaches the log, the terminal prints it. `spikes\results\s0_log.json` then shows the latency and which lengths arrived whole.
- If it ends with "no probe line reached it", Transport L is out.

### 6. File inbox (S11)

```
uv run dufleet-probe inbox --duration 120
```

Watch the panel's S11 line:
- **Works:** `seq` follows the terminal's count with a lag of a second or two.
- **Doesn't work:** it stays at the first seq, or shows `error: ...`. Copy the exact text.

### 7. HUD picture (S1)

1. Type `/b frame on` in the game. A black box with coloured squares appears at 20,200.
2. Move it with `/b at X Y` to a spot nothing on the HUD covers.
3. In the terminal:

   ```
   uv run dufleet-probe optical locate
   uv run dufleet-probe optical watch --duration 120
   ```

4. Check `spikes\results\optical_locate.png`: the four circles should sit on the white corner squares.
5. Then try the variations, re-running `optical watch` after each:
   - `/b fps 4`;
   - `/b bits 1`;
   - `/b cell 4`, which needs `optical locate` again first because the frame size changes.
6. `/b frame off` hides the frame.

### 8. Typing into chat (S3, S4)

Select the **Lua** tab of the chat, then:

```
uv run dufleet-probe inject --mode unicode --count 3
uv run dufleet-probe inject --mode scancode --count 3
uv run dufleet-probe inject --mode vk --count 3
```

- After each run, the panel's "/b lines" should have gone up by 3. Note which modes worked.
- Then run `uv run dufleet-probe inject --mode <a mode that worked> --length-sweep`. Each `@@DUB|probe|echo|...` line reports the length the game received. If a line is shorter than the number after its `L`, the chat cut it.
- If the chat opens with a key other than Enter, add `--open-key slash`, `t` or `none`.
- If the script warns about elevation, run the terminal as administrator.
- Don't touch the mouse or keyboard while it types.

### 9. CPU headroom (S10)

Fly normally with ArchHUD for a few minutes with the panel visible, then type `/b stats`. Copy the S10 line: "tick max" and "update max" against "limit".

### 10. Report

```
uv run dufleet-probe report
```

Paste `spikes\results\summary.md` back, together with:
- the panel's lines;
- the `hello` line;
- how the A1 trip went;
- what the admin agreed to (S9).

The report replaces your home folder with `~`. Still look it over before you share it.

### 11. Remove the probe

```
uv run dufleet-probe install --uninstall-probe --apply
```

This removes the shim and `dufleet\`, and restores a `userclass.lua` the install had replaced. ArchHUD and the atlas stay.

### 12. Optional: try the real bus

This step is only for when you have time left after the spikes. It swaps the probe for the bot bus under development (`lua/`), with frames going to the Lua chat.

```
uv run dufleet-probe install --bus --apply
```

Sit back in the seat. Then, in a second terminal, make command lines with correct CRCs:

```
cd companion
uv run dufleet cmd ping
uv run dufleet cmd setid hauler-1
uv run dufleet cmd status
```

Paste each printed line into the Lua chat.
- Each line gets an `@@DUB|1|...|A|...` reply.
- `status` is also followed by `H` and `T` frames.
- `dufleet cmd` counts cseq up by itself. If the bus answers `E_STATE` ("superseded"), its databank already holds a later cseq: add `--epoch 2`.

To read frames, copy them from the chat and pipe them into `uv run dufleet decode`. If S0 found the log, use `uv run dufleet decode <log file> --xml` instead.

If A1 showed that ArchHUD flies on the server, you can also try a `goto`:
1. Pick a clear spot a few hundred metres away on the same planet and copy its `::pos{...}`.
2. Write it as `pos=` with the five numbers and no `::pos{}`, since the bus refuses any line containing `::pos`:

   ```
   uv run dufleet cmd run goto j_1 pos=0,2,35.3951,104.1187,285.5413
   ```

3. Paste the line and keep your hands off the controls. Expect:
   - an `A` with `"job":"j_1"`;
   - `E` frames going `idle` to `engage` to `travel` to `settle`;
   - an `R` once the ship has landed and stood still for 5 s.
4. Try stopping one mid-flight: start another `goto`, then paste `uv run dufleet cmd cancel`. The ship should brake within 2 s.

Each `goto` needs a new job id (`j_2`, `j_3`, ...). ArchHUD lists the target as `dub-j_1` among its locations until you leave the seat. If anything looks wrong, take over as usual: ArchHUD's own keys still work.

Afterwards, `install --uninstall-probe --apply` removes the bus the same way it removes the probe.

## Troubleshooting

- **No panel:**
  - `paths` should list `archhud/userclass.lua` as "pinned".
  - A `dufleet: probe failed to load` line in the Lua chat names the problem.
- **`dufleet probe error (...)` lines:** the probe caught an error and ArchHUD kept flying. Copy the line.
- **`optical locate` finds nothing:**
  - Move the frame (`/b at 300 300`) or make it bigger (`/b cell 8`).
  - Check `optical_locate_failed.png`.
- **`inject` stops at once:** the game didn't take focus. Try `--alt-trick`, or click into the game first.

## For developers

The kit's own tests run offline, without the game. They need Lua 5.3 on `PATH` for the Lua parts:

```
cd spikes/host
uv run pytest
uv run dufleet-probe optical selftest
```

`lua/tests/test_probe.lua` drives the shim and the probe against a fake ArchHUD. The pytest suite covers several things:
- it checks that the Lua and Python frame code agree cell for cell;
- it decodes synthetic screenshots;
- it tests the log parser against partial writes, rotation and bad bytes;
- it runs the installer against a scratch Lua folder.
