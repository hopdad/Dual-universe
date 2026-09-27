-- Realtime: the companion listens for new commands on its bot; the dashboard follows
-- bots, bot_state, commands, events and goals. telemetry stays out on purpose: the UI
-- reads bot_state (one row per bot), so realtime traffic does not grow with history.
alter publication supabase_realtime add table
  public.commands, public.bot_state, public.events, public.bots, public.goals;
alter table public.commands replica identity full;
