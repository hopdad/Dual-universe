-- Verbatim from docs/handoff/original-handoff.md section 5. Defects are left in on purpose; see 0005_fixes.sql.
alter publication supabase_realtime add table public.commands, public.bot_state, public.events, public.bots, public.goals;
alter table public.commands replica identity full;
