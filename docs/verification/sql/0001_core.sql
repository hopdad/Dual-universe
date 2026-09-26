-- Verbatim from docs/handoff/original-handoff.md section 5. Defects are left in on purpose; see 0005_fixes.sql.
create extension if not exists pgcrypto;
create type bot_status as enum ('offline','launching','login','in_world','ready','busy','degraded','crashed');
create type cmd_status as enum ('queued','claimed','sent','acked','done','failed','failed_delivery','cancelled');
create type goal_status as enum ('pending','planning','active','blocked','done','failed','cancelled');

create table public.servers (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null, url text not null,
  automation_permitted boolean not null default false, notes text,
  created_at timestamptz not null default now());

create table public.bots (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  server_id uuid references public.servers(id),
  short_id text not null, host text,
  device_user_id uuid references auth.users(id),
  status bot_status not null default 'offline',
  script_version text, boot_id text, last_seen timestamptz,
  created_at timestamptz not null default now(),
  unique (owner_id, short_id));

create table public.bot_state (
  bot_id uuid primary key references public.bots(id) on delete cascade,
  pos_str text, wx double precision, wy double precision, wz double precision,
  body_id int, lat double precision, lon double precision, alt double precision,
  speed_kmh real, fuel jsonb, cargo_ratio real, skill text, skill_phase text,
  updated_at timestamptz not null default now());

create table public.telemetry (
  id bigint generated always as identity primary key,
  bot_id uuid not null references public.bots(id) on delete cascade,
  ts timestamptz not null default now(), data jsonb not null);
create index telemetry_bot_ts on public.telemetry (bot_id, ts desc);

create table public.command_seq (
  bot_id uuid primary key references public.bots(id) on delete cascade,
  next bigint not null default 1);

create table public.commands (
  id uuid primary key default gen_random_uuid(),
  bot_id uuid not null references public.bots(id) on delete cascade,
  cseq bigint, verb text not null, args jsonb not null default '{}',
  job_id text, goal_id uuid,
  status cmd_status not null default 'queued',
  attempts int not null default 0, error text, result jsonb,
  created_by text not null default 'user',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (bot_id, cseq));
create index commands_bot_status on public.commands (bot_id, status, cseq);

create table public.goals (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  bot_id uuid references public.bots(id),
  parent_id uuid references public.goals(id),
  title text not null, spec jsonb not null default '{}',
  status goal_status not null default 'pending', plan jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());

create table public.skills (
  name text primary key, version text not null,
  args_schema jsonb not null, description text not null,
  preconditions jsonb, postconditions jsonb,
  success_count int not null default 0, failure_count int not null default 0);

create table public.events (
  id bigint generated always as identity primary key,
  bot_id uuid references public.bots(id) on delete cascade,
  ts timestamptz not null default now(),
  kind text not null, severity smallint not null default 0, data jsonb not null);
create index events_bot_ts on public.events (bot_id, ts desc);

create or replace function public.assign_cseq() returns trigger language plpgsql as $$
begin
  insert into public.command_seq(bot_id) values (new.bot_id) on conflict do nothing;
  update public.command_seq set next = next + 1 where bot_id = new.bot_id
    returning next - 1 into new.cseq;
  return new;
end $$;
create trigger commands_cseq before insert on public.commands
  for each row when (new.cseq is null) execute function public.assign_cseq();

create or replace function public.claim_next_command(p_bot uuid) returns public.commands
language sql security invoker as $$
  update public.commands c set status='claimed', attempts=attempts+1, updated_at=now()
  where c.id = (select id from public.commands where bot_id=p_bot and status='queued'
                order by cseq limit 1 for update skip locked)
  returning c.*;
$$;
