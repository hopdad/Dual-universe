-- A device asks its bus to send lost frames again (docs/protocol.md, "Jobs"). The ask is a
-- `resend` command, numbered by the hub like any other so the bus's dedupe holds. Devices
-- cannot insert commands, so this is the one command they may queue. A queued resend that
-- starts at or before p_from already covers it (the bus sends every replayable frame from
-- `from` on), so it is returned instead of a second one.
create function public.request_resend(p_bot uuid, p_from bigint)
returns public.commands
language plpgsql security definer set search_path = '' as $$
declare
  r public.commands;
begin
  if not public.is_bot_device(p_bot) then
    raise exception 'no bot % for this device', p_bot using errcode = '42501';
  end if;
  if p_from is null or p_from < 0 or p_from > 4294967295 then
    raise exception 'from % is out of range', p_from using errcode = '22023';
  end if;
  select * into r from public.commands
   where bot_id = p_bot and verb = 'resend' and status = 'queued' and (args ->> 0)::bigint <= p_from
   order by epoch, cseq
   limit 1;
  if found then
    return r;
  end if;
  insert into public.commands (bot_id, verb, args, created_by)
  values (p_bot, 'resend', jsonb_build_array(p_from::text), 'companion')
  returning * into r;
  return r;
end $$;

revoke all on function public.request_resend(uuid, bigint) from public, anon;
grant execute on function public.request_resend(uuid, bigint) to authenticated;
