-- Corrective migration for defects found while verifying the handoff schema.

-- (1) command_seq: not an API table. Lock it down; only the SECURITY DEFINER trigger touches it.
alter table public.command_seq enable row level security;
revoke all on public.command_seq from anon, authenticated;

-- (2) cseq is always server-assigned and immutable; clients cannot pick or rewrite it.
create or replace function public.assign_cseq() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.command_seq(bot_id) values (new.bot_id) on conflict do nothing;
  update public.command_seq set next = next + 1 where bot_id = new.bot_id
    returning next - 1 into new.cseq;
  return new;
end $$;
drop trigger commands_cseq on public.commands;
create trigger commands_cseq before insert on public.commands
  for each row execute function public.assign_cseq();

create or replace function public.commands_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.cseq is distinct from old.cseq or new.bot_id is distinct from old.bot_id
     or new.verb is distinct from old.verb or new.args is distinct from old.args then
    raise exception 'commands: cseq, bot_id, verb and args are immutable';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger commands_guard before update on public.commands
  for each row execute function public.commands_guard();

-- (3) claim: SETOF (empty queue => zero rows) and at most one command in flight per bot.
drop function public.claim_next_command(uuid);
create function public.claim_next_command(p_bot uuid) returns setof public.commands
language sql security invoker set search_path = '' as $$
  update public.commands c set status = 'claimed', attempts = c.attempts + 1
  where c.id = (select q.id from public.commands q
                where q.bot_id = p_bot and q.status = 'queued'
                  and not exists (select 1 from public.commands f
                                  where f.bot_id = p_bot and f.status in ('claimed','sent'))
                order by q.cseq limit 1 for update skip locked)
  returning c.*;
$$;

-- (4) device users no longer update bots directly; they report through a narrow RPC.
drop policy bots_device_update on public.bots;
create function public.bot_report(p_bot uuid, p_status public.bot_status,
                                  p_script_version text, p_boot_id text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.bots set status = p_status, script_version = p_script_version,
         boot_id = p_boot_id, last_seen = now()
   where id = p_bot and device_user_id = (select auth.uid());
  if not found then raise exception 'not the device user of bot %', p_bot; end if;
end $$;
revoke execute on function public.bot_report(uuid, public.bot_status, text, text) from anon;

-- (5) events are always owned; no cross-tenant "global" rows.
alter table public.events add column owner_id uuid references auth.users(id) on delete cascade;
update public.events e set owner_id = b.owner_id from public.bots b where b.id = e.bot_id;
alter table public.events alter column owner_id set default auth.uid();
alter table public.events alter column owner_id set not null;
drop policy ev_rw on public.events;
create policy ev_rw on public.events for all
  using (owner_id = (select auth.uid()) or (bot_id is not null and public.can_access_bot(bot_id)))
  with check (owner_id = (select auth.uid()) or (bot_id is not null and public.can_access_bot(bot_id)));

-- (6) housekeeping
alter table public.goals drop constraint goals_bot_id_fkey,
  add constraint goals_bot_id_fkey foreign key (bot_id) references public.bots(id) on delete set null;
drop policy skills_read on public.skills;
create policy skills_read on public.skills for select to authenticated using (true);
