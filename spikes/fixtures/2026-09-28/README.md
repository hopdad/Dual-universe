# Probe kit session 1, 2026-09-28

Raw results from the first in-game session on The Third Verse ([docs/spikes.md](../../../docs/spikes.md)), kept as fixtures for the transports ([ADR-0001](../../../docs/adr/0001-transports.md)). The session's other result files hold local paths and stay out of the repository.

| File | What it is |
|---|---|
| `optical_locate_cell6.png`, `optical_calibration_cell6.json` | The optical frame found on screen (2560×1600) with 6 px cells, and its calibration |
| `s1_optical_cell6_2fps.json` | Decode results, 6 px cells at 2 frames per second: 1,195 captures, 0 errors |
| `optical_locate_cell4.png`, `optical_calibration_cell4.json` | The same with 4 px cells |
| `s1_optical_cell4_4fps.json` | Decode results, 4 px cells at 4 frames per second: 1,196 captures, 0 errors |
| `s11_inbox_host.json` | The companion side of the inbox test: 180 writes, one per second, no rename retries |
