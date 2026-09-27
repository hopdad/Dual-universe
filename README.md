# Dual-universe

A bot fleet for myDU (self-hosted Dual Universe). It has five parts:

- Lua running in the game client;
- a companion process on each client host;
- a Supabase hub;
- a Next.js dashboard;
- an LLM planner that only composes vetted skills.

Status: Phase 0 (spikes and decision gates). The transport-independent Phase 1 work is built and tested in CI. The transports wait for the spike results (ADR-0001). Client-only, flying with ArchHUD.

- [Wire protocol v1](docs/protocol.md), defined in [packages/protocol](packages/protocol/) and shared by the Lua bus and the companion
- [Lua bus](lua/README.md), which runs inside ArchHUD
- [Hub schema](supabase/README.md): Supabase migrations, RPCs and scenario tests
- [Companion](companion/README.md): command pump, frame router, Supabase client, `dufleet` CLI
- [Dashboard](dashboard/README.md): Next.js 16 fleet view

- [Development plan](docs/plan.md) and [decision records](docs/adr/)
- [Phase 0 probe kit](spikes/README.md): the in-game session that answers the open spikes
- [Handoff verification](docs/verification.md) and its [reproducible checks](docs/verification/)
- [Original handoff spec](docs/handoff/original-handoff.md)
- [CLAUDE.md](CLAUDE.md), working rules for Claude Code in this repository
