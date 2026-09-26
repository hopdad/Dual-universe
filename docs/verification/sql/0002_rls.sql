-- Verbatim from docs/handoff/original-handoff.md section 5. Defects are left in on purpose; see 0005_fixes.sql.
alter table public.servers   enable row level security;
alter table public.bots      enable row level security;
alter table public.bot_state enable row level security;
alter table public.telemetry enable row level security;
alter table public.commands  enable row level security;
alter table public.goals     enable row level security;
alter table public.events    enable row level security;
alter table public.skills    enable row level security;

create or replace function public.can_access_bot(p_bot uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from bots b where b.id = p_bot
    and (b.owner_id = auth.uid() or b.device_user_id = auth.uid()));
$$;

create policy servers_owner on public.servers for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy bots_owner on public.bots for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy bots_device_read on public.bots for select using (device_user_id = auth.uid());
create policy bots_device_update on public.bots for update using (device_user_id = auth.uid());
create policy state_rw on public.bot_state for all using (public.can_access_bot(bot_id)) with check (public.can_access_bot(bot_id));
create policy tel_rw on public.telemetry for all using (public.can_access_bot(bot_id)) with check (public.can_access_bot(bot_id));
create policy cmd_rw on public.commands for all using (public.can_access_bot(bot_id)) with check (public.can_access_bot(bot_id));
create policy ev_rw on public.events for all using (bot_id is null or public.can_access_bot(bot_id)) with check (bot_id is null or public.can_access_bot(bot_id));
create policy goals_owner on public.goals for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy skills_read on public.skills for select using (auth.role() = 'authenticated');
