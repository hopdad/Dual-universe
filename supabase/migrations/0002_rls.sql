-- Who may touch what. Row level security picks the rows; grants pick the operations
-- and columns, so clients can never write cseq, epoch, status or ownership directly.
--
-- Two kinds of signed-in user:
--   owner   the person who owns servers, bots, goals and commands (dashboard, planner);
--   device  the login a companion uses for one bot (bots.device_user_id).
-- Devices write state, telemetry and events for their own bot, and move commands only
-- through the RPCs in 0003_rpc.sql. Nothing uses the service role.

create function public.is_bot_owner(p_bot uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.bots b where b.id = p_bot and b.owner_id = (select auth.uid()));
$$;

create function public.is_bot_device(p_bot uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.bots b where b.id = p_bot and b.device_user_id = (select auth.uid()));
$$;

create function public.can_access_bot(p_bot uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.bots b where b.id = p_bot
    and (select auth.uid()) in (b.owner_id, b.device_user_id));
$$;

alter table public.servers enable row level security;
alter table public.bots enable row level security;
alter table public.bot_state enable row level security;
alter table public.telemetry enable row level security;
alter table public.command_seq enable row level security;
alter table public.goals enable row level security;
alter table public.commands enable row level security;
alter table public.skills enable row level security;
alter table public.events enable row level security;

-- Supabase grants everything to the API roles by default; start these tables and
-- functions from nothing instead. Later migrations must do the same for what they add
-- (supabase/tests checks that no function in public is executable by anon or PUBLIC).
revoke all on public.servers, public.bots, public.bot_state, public.telemetry, public.command_seq,
  public.goals, public.commands, public.skills, public.events from anon, authenticated;
revoke all on function public.set_updated_at(), public.commands_before_insert(), public.commands_before_update(),
  public.events_before_insert(), public.is_bot_owner(uuid), public.is_bot_device(uuid), public.can_access_bot(uuid)
  from public, anon, authenticated;

grant select, insert, update, delete on public.servers, public.goals to authenticated;
grant select, delete on public.bots to authenticated;
grant insert (server_id, short_id, host, device_user_id), update (server_id, short_id, host, device_user_id)
  on public.bots to authenticated;
grant select, insert, update on public.bot_state to authenticated;
grant select, insert on public.telemetry to authenticated;
grant select on public.commands to authenticated;
grant insert (bot_id, verb, args, job_id, goal_id, created_by) on public.commands to authenticated;
grant select on public.skills to authenticated;
grant select on public.events to authenticated;
grant insert (bot_id, kind, severity, data) on public.events to authenticated;
grant execute on function public.is_bot_owner(uuid), public.is_bot_device(uuid), public.can_access_bot(uuid)
  to authenticated;

create policy servers_owner on public.servers for all to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));

create policy bots_owner on public.bots for all to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy bots_device_read on public.bots for select to authenticated
  using (device_user_id = (select auth.uid()));

create policy bot_state_read on public.bot_state for select to authenticated
  using (public.can_access_bot(bot_id));
create policy bot_state_device_insert on public.bot_state for insert to authenticated
  with check (public.is_bot_device(bot_id));
create policy bot_state_device_update on public.bot_state for update to authenticated
  using (public.is_bot_device(bot_id)) with check (public.is_bot_device(bot_id));

create policy telemetry_read on public.telemetry for select to authenticated
  using (public.can_access_bot(bot_id));
create policy telemetry_device_insert on public.telemetry for insert to authenticated
  with check (public.is_bot_device(bot_id));

create policy goals_owner on public.goals for all to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));

create policy commands_read on public.commands for select to authenticated
  using (public.can_access_bot(bot_id));
create policy commands_owner_insert on public.commands for insert to authenticated
  with check (public.is_bot_owner(bot_id));

create policy skills_read on public.skills for select to authenticated
  using (true);

create policy events_read on public.events for select to authenticated
  using (owner_id = (select auth.uid()) or (bot_id is not null and public.can_access_bot(bot_id)));
create policy events_insert on public.events for insert to authenticated
  with check (case when bot_id is null then owner_id = (select auth.uid()) else public.can_access_bot(bot_id) end);

-- command_seq: row level security on, no policies, no grants.
