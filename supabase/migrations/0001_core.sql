-- mydu-fleet hub: types, tables and triggers.
-- Replaces the handoff's 0001-0004 and folds in docs/verification/sql/0005_fixes.sql.
-- Access rules are in 0002_rls.sql, the RPCs in 0003_rpc.sql. See supabase/README.md.

create type public.bot_status as enum ('offline', 'launching', 'login', 'in_world', 'ready', 'busy', 'degraded', 'crashed');
create type public.cmd_status as enum ('queued', 'claimed', 'sent', 'acked', 'done', 'failed', 'failed_delivery', 'cancelled');
create type public.goal_status as enum ('pending', 'planning', 'active', 'blocked', 'done', 'failed', 'cancelled');

create function public.set_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

create table public.servers (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name text not null,
  url text not null,
  automation_permitted boolean not null default false, -- spike S9: the admin's written permission
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.bots (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  server_id uuid references public.servers (id) on delete set null,
  short_id text not null check (short_id ~ '^[A-Za-z0-9_-]{1,16}$'), -- the id in frames, set with `setid`
  host text,
  device_user_id uuid references auth.users (id) on delete set null, -- the companion's login
  status public.bot_status not null default 'offline',
  script_version text,
  archhud_version text,
  boot_id text,
  epoch integer not null default 1, -- copy of command_seq.epoch for the dashboard
  last_seen timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, short_id)
);

-- Latest state per bot; the dashboard subscribes to this, not to telemetry.
create table public.bot_state (
  bot_id uuid primary key references public.bots (id) on delete cascade,
  wx double precision,
  wy double precision,
  wz double precision,
  body_id integer,
  lat double precision,
  lon double precision,
  alt double precision,
  speed_kmh real,
  fuel jsonb,
  cargo_ratio real,
  skill text,
  skill_phase text,
  autopilot text,
  updated_at timestamptz not null default now()
);

create table public.telemetry (
  id bigint generated always as identity primary key,
  bot_id uuid not null references public.bots (id) on delete cascade,
  ts timestamptz not null default now(),
  data jsonb not null
);
create index telemetry_bot_ts on public.telemetry (bot_id, ts desc);

-- Command numbering per bot (docs/protocol.md, "Delivery, dedupe and epochs"). Not an
-- API table: only the SECURITY DEFINER code below and in 0003_rpc.sql touches it.
create table public.command_seq (
  bot_id uuid primary key references public.bots (id) on delete cascade,
  epoch integer not null default 1 check (epoch between 1 and 65535),
  next bigint not null default 1 check (next between 1 and 2147483648)
);

create table public.goals (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  bot_id uuid references public.bots (id) on delete set null,
  parent_id uuid references public.goals (id) on delete cascade,
  title text not null,
  spec jsonb not null default '{}',
  status public.goal_status not null default 'pending',
  plan jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- args holds the command's arguments as strings, in order: ["goto", "j_7a1", "pos=0,2,35.39,104.11,285.5"].
create table public.commands (
  id uuid primary key default gen_random_uuid(),
  bot_id uuid not null references public.bots (id) on delete cascade,
  epoch integer not null,
  cseq bigint not null check (cseq between 1 and 2147483647),
  verb text not null check (verb ~ '^[a-z]+$'),
  args jsonb not null default '[]' check (jsonb_typeof(args) = 'array'),
  job_id text check (job_id ~ '^j_[A-Za-z0-9]{1,16}$'),
  goal_id uuid references public.goals (id) on delete set null,
  status public.cmd_status not null default 'queued',
  attempts integer not null default 0,
  error text,
  result jsonb,
  created_by text not null default 'user',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  claimed_at timestamptz, -- the lease: an in-flight command can be claimed again once it is old enough
  sent_at timestamptz,
  acked_at timestamptz,
  finished_at timestamptz,
  unique (bot_id, epoch, cseq)
);
create index commands_bot_status on public.commands (bot_id, status, epoch, cseq);

create table public.skills (
  name text primary key,
  version text not null,
  args_schema jsonb not null,
  description text not null,
  preconditions jsonb,
  postconditions jsonb,
  success_count integer not null default 0,
  failure_count integer not null default 0
);

-- Events always have an owner: the bot's owner, or for events without a bot, whoever wrote them.
create table public.events (
  id bigint generated always as identity primary key,
  owner_id uuid not null references auth.users (id) on delete cascade,
  bot_id uuid references public.bots (id) on delete cascade,
  ts timestamptz not null default now(),
  kind text not null,
  severity smallint not null default 0 check (severity between 0 and 3),
  data jsonb not null default '{}'
);
create index events_bot_ts on public.events (bot_id, ts desc);
create index events_owner_ts on public.events (owner_id, ts desc);

-- Every new command gets the bot's current epoch and next cseq, whatever the client sent.
create function public.commands_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.command_seq (bot_id) values (new.bot_id) on conflict do nothing;
  update public.command_seq set next = next + 1 where bot_id = new.bot_id
    returning epoch, next - 1 into new.epoch, new.cseq;
  new.status := 'queued';
  new.attempts := 0;
  new.error := null;
  new.result := null;
  new.created_at := now();
  new.updated_at := now();
  new.claimed_at := null;
  new.sent_at := null;
  new.acked_at := null;
  new.finished_at := null;
  return new;
end $$;
create trigger commands_before_insert before insert on public.commands
  for each row execute function public.commands_before_insert();

-- What a command says never changes after it is queued.
create function public.commands_before_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.bot_id is distinct from old.bot_id or new.epoch is distinct from old.epoch
     or new.cseq is distinct from old.cseq or new.verb is distinct from old.verb
     or new.args is distinct from old.args or new.job_id is distinct from old.job_id
     or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception 'commands: bot_id, epoch, cseq, verb, args, job_id, created_by and created_at are immutable'
      using errcode = '42501';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger commands_before_update before update on public.commands
  for each row execute function public.commands_before_update();

create function public.events_before_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.bot_id is null then
    new.owner_id := auth.uid();
  else
    select b.owner_id into new.owner_id from public.bots b where b.id = new.bot_id;
  end if;
  return new;
end $$;
create trigger events_before_insert before insert on public.events
  for each row execute function public.events_before_insert();

create trigger servers_updated_at before update on public.servers
  for each row execute function public.set_updated_at();
create trigger bots_updated_at before update on public.bots
  for each row execute function public.set_updated_at();
create trigger bot_state_updated_at before update on public.bot_state
  for each row execute function public.set_updated_at();
create trigger goals_updated_at before update on public.goals
  for each row execute function public.set_updated_at();
