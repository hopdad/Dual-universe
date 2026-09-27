-- RPCs. Devices move commands and report status only through these; owners cancel
-- queued commands. Every function checks the caller itself (SECURITY DEFINER).

-- The next command to deliver, or nothing. One command per bot is in flight
-- (claimed or sent) at a time. An in-flight command whose lease is older than
-- p_lease_s seconds is handed out again, with the same epoch and cseq, so a companion
-- that died mid-delivery never loses it; the bus answers a repeat from its stored reply.
create function public.claim_next_command(p_bot uuid, p_lease_s integer default 30)
returns setof public.commands
language plpgsql security definer set search_path = '' as $$
declare
  r public.commands;
begin
  if not public.is_bot_device(p_bot) then
    raise exception 'not the device user of bot %', p_bot using errcode = '42501';
  end if;
  -- One claim per bot at a time, so two callers cannot both see "nothing in flight".
  insert into public.command_seq (bot_id) values (p_bot) on conflict do nothing;
  perform 1 from public.command_seq where bot_id = p_bot for update;

  select * into r from public.commands
   where bot_id = p_bot and status in ('claimed', 'sent')
   order by epoch, cseq limit 1;
  if found then
    if coalesce(r.claimed_at, '-infinity') <= now() - make_interval(secs => greatest(p_lease_s, 0)) then
      update public.commands set claimed_at = now(), attempts = attempts + 1
       where id = r.id returning * into r;
      return next r;
    end if;
    return;
  end if;

  update public.commands set status = 'claimed', claimed_at = now(), attempts = attempts + 1
   where id = (select q.id from public.commands q
                where q.bot_id = p_bot and q.status = 'queued'
                order by q.epoch, q.cseq limit 1)
  returning * into r;
  if found then
    return next r;
  end if;
end $$;

-- For a companion that restarts: the command it had in flight, with a fresh lease, or
-- nothing. Never claims a new command.
create function public.recover_inflight(p_bot uuid)
returns setof public.commands
language plpgsql security definer set search_path = '' as $$
declare
  r public.commands;
begin
  if not public.is_bot_device(p_bot) then
    raise exception 'not the device user of bot %', p_bot using errcode = '42501';
  end if;
  insert into public.command_seq (bot_id) values (p_bot) on conflict do nothing;
  perform 1 from public.command_seq where bot_id = p_bot for update;
  update public.commands set claimed_at = now(), attempts = attempts + 1
   where id = (select f.id from public.commands f
                where f.bot_id = p_bot and f.status in ('claimed', 'sent')
                order by f.epoch, f.cseq limit 1)
  returning * into r;
  if found then
    return next r;
  end if;
end $$;

-- Records what happened to a claimed command. Allowed moves:
--   claimed -> sent, acked, done, failed, failed_delivery
--   sent    -> acked, done, failed, failed_delivery
--   acked   -> done, failed
-- Repeating the current status is a no-op, so retries are safe.
create function public.command_progress(p_id uuid, p_status public.cmd_status,
                                        p_error text default null, p_result jsonb default null)
returns public.commands
language plpgsql security definer set search_path = '' as $$
declare
  r public.commands;
begin
  select * into r from public.commands where id = p_id for update;
  if not found or not public.is_bot_device(r.bot_id) then
    raise exception 'no command % for this device', p_id using errcode = '42501';
  end if;
  if r.status = p_status then
    return r;
  end if;
  if not (case r.status
            when 'claimed' then p_status in ('sent', 'acked', 'done', 'failed', 'failed_delivery')
            when 'sent' then p_status in ('acked', 'done', 'failed', 'failed_delivery')
            when 'acked' then p_status in ('done', 'failed')
            else false end) then
    raise exception 'command % cannot go from % to %', r.cseq, r.status, p_status using errcode = '22023';
  end if;
  update public.commands set
      status = p_status,
      error = coalesce(p_error, error),
      result = coalesce(p_result, result),
      sent_at = case when p_status = 'sent' then now() else sent_at end,
      acked_at = case when p_status = 'acked' then now() else acked_at end,
      finished_at = case when p_status in ('done', 'failed', 'failed_delivery') then now() else finished_at end
   where id = p_id
  returning * into r;
  return r;
end $$;

-- Owners take back a command that has not been claimed yet.
create function public.cancel_command(p_id uuid)
returns public.commands
language plpgsql security definer set search_path = '' as $$
declare
  r public.commands;
begin
  select * into r from public.commands where id = p_id for update;
  if not found or not public.is_bot_owner(r.bot_id) then
    raise exception 'no command % for this user', p_id using errcode = '42501';
  end if;
  if r.status <> 'queued' then
    raise exception 'command % is %, only queued commands can be cancelled', r.cseq, r.status using errcode = '22023';
  end if;
  update public.commands set status = 'cancelled', finished_at = now() where id = p_id returning * into r;
  return r;
end $$;

-- A device reports its bot's status and versions (from the H frame).
create function public.bot_report(p_bot uuid, p_status public.bot_status, p_script_version text,
                                  p_boot_id text, p_archhud_version text default null)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.bots set status = p_status, script_version = p_script_version, boot_id = p_boot_id,
         archhud_version = coalesce(p_archhud_version, archhud_version), last_seen = now()
   where id = p_bot and device_user_id = (select auth.uid());
  if not found then
    raise exception 'not the device user of bot %', p_bot using errcode = '42501';
  end if;
end $$;

-- A device passes on the watermark from its bot's H frame (epoch, cseq). If the bot
-- is ahead of the hub, which happens only after the hub lost its numbering, the hub
-- moves to a new epoch so that its next commands run instead of being refused as
-- superseded. Queued commands of the old epoch are cancelled. Returns the hub's epoch.
create function public.sync_epoch(p_bot uuid, p_epoch integer, p_cseq bigint)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  s public.command_seq;
begin
  if not public.is_bot_device(p_bot) then
    raise exception 'not the device user of bot %', p_bot using errcode = '42501';
  end if;
  insert into public.command_seq (bot_id) values (p_bot) on conflict do nothing;
  select * into s from public.command_seq where bot_id = p_bot for update;
  if p_epoch > s.epoch or (p_epoch = s.epoch and p_cseq >= s.next) then
    s.epoch := greatest(s.epoch, p_epoch) + 1;
    if s.epoch > 65535 then
      raise exception 'bot % has used every epoch', p_bot using errcode = '22003';
    end if;
    update public.command_seq set epoch = s.epoch, next = 1 where bot_id = p_bot;
    update public.bots set epoch = s.epoch where id = p_bot;
    update public.commands set status = 'cancelled', error = 'epoch changed', finished_at = now()
     where bot_id = p_bot and status = 'queued' and epoch < s.epoch;
    insert into public.events (bot_id, kind, severity, data)
    values (p_bot, 'epoch_changed', 1,
            jsonb_build_object('epoch', s.epoch, 'bot_epoch', p_epoch, 'bot_cseq', p_cseq));
  end if;
  return s.epoch;
end $$;

revoke all on function public.claim_next_command(uuid, integer), public.recover_inflight(uuid),
  public.command_progress(uuid, public.cmd_status, text, jsonb), public.cancel_command(uuid),
  public.bot_report(uuid, public.bot_status, text, text, text), public.sync_epoch(uuid, integer, bigint)
  from public, anon;
grant execute on function public.claim_next_command(uuid, integer), public.recover_inflight(uuid),
  public.command_progress(uuid, public.cmd_status, text, jsonb), public.cancel_command(uuid),
  public.bot_report(uuid, public.bot_status, text, text, text), public.sync_epoch(uuid, integer, bigint)
  to authenticated;
