# ADR-0001: Telemetry through a HUD frame, commands through an inbox file

- Status: Accepted, 2026-09-28. Follows the rule [plan.md](../plan.md) set for gates D2 and D3.
- Decides: gates D2 (telemetry out) and D3 (commands in). Evidence: session 1 in [spikes.md](../spikes.md).

## Context

- The bus runs inside ArchHUD's control unit, on a client whose server we do not change ([ADR-0002](0002-archhud-extension.md), [ADR-0003](0003-client-only-track.md)). It needs one way to send frames to the companion on the same PC, and one way to receive commands.
- Out, the candidates were L (the client's log file) and O (an optical frame drawn through ArchHUD's `userScreen` and read by screen capture). In, they were F (a Lua file the companion writes and the bus reads again) and C (chat keystrokes).
- The plan's rule: L if S0 passes, otherwise O; F if S11 passes, otherwise C.
- S0 failed: no `system.print` line reaches the log.
- S11 passed: after `package.loaded[name]` is cleared, `require` reads the current file, within 0.6 s of the write, for 37 instructions.
- S1 passed: 2,391 captures decoded without a cell error, with 6 px cells at 2 fps and with 4 px cells at 4 fps.

## Decision

1. **Out: Transport O.** The bus draws frames into `userScreen`; the companion captures that region of the screen and decodes it.
   - Default: 48×24 cells, 2 bits per cell, 6 px cells, 2 frames per second. That is 288 bytes per frame before the frame's own header and checksum.
   - 4 px cells at 4 frames per second also passed. It is the option for more throughput or less HUD space.
2. **In: Transport F.** The companion writes `autoconf/custom/dufleet/inbox.lua` as a temp file and renames it over the old one. The bus polls every 0.5 s: it clears `package.loaded` and calls `require`.
   - The file returns data only: the epoch and every pending command with its CRC.
   - It carries every pending command, not just the newest, because a poll can miss a version (S11 saw 179 of 180).
3. **Chat keystrokes (C) are not a command path.** The chat grammar stays for manual tests, and the injector is still built, for login and menus (S3, S4).

## Consequences

- The frame must stay visible. That means one client per desktop or VM, and a console session that stays unlocked (already a rule). Nothing may cover the frame: menus, the chat window, other windows.
- Each bot host needs screen capture, and write access to `autoconf/custom/dufleet/`. Where that folder's files belong to Administrators, grant Modify once (S8).
- Building a frame costs about 53,000 instructions, the bus's largest single cost. At 2 fps that is about 5% of the limit twice a second. S10 found at most 12% of the limit in use.
- Throughput at 2 fps is about 576 bytes per second before framing, more than 1 Hz telemetry needs. A long reply spans several frames.
- Lost frames: none in 681. A frame can still be lost while the window is covered or the HUD is hidden. So the result recovery (`request_resend`) stays, and no per-`seq` gap tracking is added for now.
- The log is not a data channel. ArchHUD's flush warnings grow it by about 80 MB per hour, so the watchdog should delete old logs.
- Work that follows ("Next steps" in [plan.md](../plan.md#next-steps)):
  - the bus's `optical` and `inbox` transports behind `dufleet.transport`;
  - the frame format for protocol data;
  - the companion's frame reader (from the probe kit's decoder) and inbox writer;
  - tests on the session 1 fixtures ([spikes/fixtures/2026-09-28/](../../spikes/fixtures/2026-09-28/)).
