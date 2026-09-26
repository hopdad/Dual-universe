# ADR-0003: Client-only track

- Status: Accepted, 2026-09-26
- Decides: gate D0 in [plan.md](../plan.md)

## Context

The verification found a clean myDU path. Lua can send data to a server mod with `system.modAction`, and a mod can raise Lua events in a client through injected JavaScript. That path needs a DLL mod installed on the server.

The project owner plays as a general player and cannot install server mods.

## Decision

Build only the client-side track (track C). Nothing may depend on server mods, server-side APIs, or backoffice access.

## Consequences

- Telemetry out has two candidates: Transport L (log tail, spike S0) or Transport O (optical HUD frame, spike S1). ADR-0001 picks one.
- Commands in use chat keystrokes (Transport C), unless spike S11 shows the game can re-read a local Lua file at runtime (Transport F). ADR-0001 records the result.
- Spikes M1–M3, the `mod/` directory and the server-side market plan are dropped.
- The go-live gate S9 still applies. Client-side automation needs the server admin's written permission, even though the admin installs nothing.
- If an admin later offers to install a mod, reopen this ADR. The hub, dashboard, planner and Lua core carry over unchanged.
