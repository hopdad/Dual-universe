# Dual-universe

A bot fleet for myDU (self-hosted Dual Universe). It has five parts:

- Lua running in the game client;
- a companion process on each client host;
- a Supabase hub;
- a Next.js dashboard;
- an LLM planner that only composes vetted skills.

Status: Phase 0 (spikes and decision gates). No application code yet. Client-only, flying with ArchHUD.

- [Development plan](docs/plan.md) and [decision records](docs/adr/)
- [Handoff verification](docs/verification.md) and its [reproducible checks](docs/verification/)
- [Original handoff spec](docs/handoff/original-handoff.md)
- [CLAUDE.md](CLAUDE.md), working rules for Claude Code in this repository
