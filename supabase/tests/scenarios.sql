-- Hub scenarios: run by run.sh after 00_platform_stub.sql and the migrations.
-- Every check raises on failure, and psql stops at the first one (ON_ERROR_STOP).
--
-- People: owner A and owner B; device DA is the companion login for A's bot, DB for B's.
\set QUIET 1
\o /dev/null
\set as_admin 'reset role; set request.jwt.claim.sub = '''';'
\set as_anon 'reset role; set request.jwt.claim.sub = ''''; set role anon;'
\set as_owner_a 'reset role; set request.jwt.claim.sub = ''aaaaaaaa-0000-0000-0000-000000000001''; set role authenticated;'
\set as_owner_b 'reset role; set request.jwt.claim.sub = ''bbbbbbbb-0000-0000-0000-000000000002''; set role authenticated;'
\set as_device_a 'reset role; set request.jwt.claim.sub = ''dddddddd-0000-0000-0000-000000000003''; set role authenticated;'
\set as_device_b 'reset role; set request.jwt.claim.sub = ''eeeeeeee-0000-0000-0000-000000000004''; set role authenticated;'

:as_admin
create schema test;
grant usage on schema test to anon, authenticated;
-- Runs p_sql as the current role and checks that it fails with SQLSTATE p_state.
create function test.expect_error(p_sql text, p_state text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state then
      return;
    end if;
    raise exception 'expected % from [%], got %: %', p_state, p_sql, sqlstate, sqlerrm;
  end;
  raise exception 'expected % from [%], but it succeeded', p_state, p_sql;
end $$;
create function test.cmd(p_cseq bigint, p_epoch integer default 1) returns uuid language sql as $$
  select id from public.commands where bot_id = '22222222-0000-0000-0000-000000000001'
    and cseq = p_cseq and epoch = p_epoch
$$;
grant execute on all functions in schema test to anon, authenticated;

insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'owner-a'), ('bbbbbbbb-0000-0000-0000-000000000002', 'owner-b'),
  ('dddddddd-0000-0000-0000-000000000003', 'device-a'), ('eeeeeeee-0000-0000-0000-000000000004', 'device-b');

\echo 'H1 owners create servers and bots; ownership comes from the login'
:as_owner_a
insert into public.servers (id, name, url) values ('11111111-0000-0000-0000-000000000001', 'The Third Verse', 'https://example.invalid');
insert into public.bots (server_id, short_id, device_user_id)
values ('11111111-0000-0000-0000-000000000001', 'hauler-1', 'dddddddd-0000-0000-0000-000000000003');
select test.expect_error($q$insert into public.bots (owner_id, short_id) values ('bbbbbbbb-0000-0000-0000-000000000002', 'x')$q$, '42501');
select test.expect_error($q$insert into public.bots (short_id) values ('bad id!')$q$, '23514');
:as_admin
update public.bots set id = '22222222-0000-0000-0000-000000000001' where short_id = 'hauler-1';
:as_owner_b
insert into public.bots (short_id, device_user_id) values ('miner-1', 'eeeeeeee-0000-0000-0000-000000000004');
:as_admin
update public.bots set id = '22222222-0000-0000-0000-000000000002' where short_id = 'miner-1';
do $$ begin
  assert (select owner_id from public.bots where short_id = 'hauler-1') = 'aaaaaaaa-0000-0000-0000-000000000001', 'A owns hauler-1';
  assert (select epoch from public.bots where short_id = 'hauler-1') = 1, 'bots start at epoch 1';
end $$;

\echo 'H2 the hub numbers commands; clients cannot pick epoch, cseq or status'
:as_owner_a
insert into public.commands (bot_id, verb) values ('22222222-0000-0000-0000-000000000001', 'ping');
insert into public.commands (bot_id, verb) values ('22222222-0000-0000-0000-000000000001', 'status');
insert into public.commands (bot_id, verb, args, job_id)
values ('22222222-0000-0000-0000-000000000001', 'run', '["patrol", "j_p1"]', 'j_p1');
do $$ begin
  assert (select string_agg(epoch || '.' || cseq || ':' || status, ' ' order by cseq) from public.commands)
    = '1.1:queued 1.2:queued 1.3:queued', 'cseq 1, 2, 3 in epoch 1, all queued';
end $$;
select test.expect_error($q$insert into public.commands (bot_id, verb, cseq) values ('22222222-0000-0000-0000-000000000001', 'ping', 999)$q$, '42501');
select test.expect_error($q$insert into public.commands (bot_id, verb, epoch) values ('22222222-0000-0000-0000-000000000001', 'ping', 9)$q$, '42501');
select test.expect_error($q$insert into public.commands (bot_id, verb, status) values ('22222222-0000-0000-0000-000000000001', 'ping', 'done')$q$, '42501');
select test.expect_error($q$insert into public.commands (bot_id, verb, args) values ('22222222-0000-0000-0000-000000000001', 'ping', '{}')$q$, '23514');
select test.expect_error($q$insert into public.commands (bot_id, verb) values ('22222222-0000-0000-0000-000000000002', 'ping')$q$, '42501');
select test.expect_error($q$update public.commands set status = 'done'$q$, '42501');
select test.expect_error($q$delete from public.commands$q$, '42501');

\echo 'H3 bots and their commands are visible to the bot owner and its device only'
:as_device_a
do $$ begin
  assert (select count(*) from public.commands) = 3, 'device A sees its bot''s 3 commands';
  assert (select string_agg(short_id, ',') from public.bots) = 'hauler-1', 'device A sees only its bot';
end $$;
:as_owner_b
do $$ begin
  assert (select count(*) from public.commands) = 0, 'owner B sees none of A''s commands';
  assert (select string_agg(short_id, ',') from public.bots) = 'miner-1', 'owner B sees only its bot';
  assert (select count(*) from public.servers) = 0, 'owner B sees none of A''s servers';
end $$;
:as_device_b
do $$ begin
  assert (select count(*) from public.commands) = 0, 'device B sees none of A''s commands';
  assert (select string_agg(short_id, ',') from public.bots) = 'miner-1', 'device B sees only its bot';
end $$;
:as_anon
select test.expect_error($q$select count(*) from public.commands$q$, '42501');
select test.expect_error($q$select count(*) from public.bots$q$, '42501');
select test.expect_error($q$select * from public.claim_next_command('22222222-0000-0000-0000-000000000001')$q$, '42501');

\echo 'H4 claim: only the device, one command in flight'
:as_owner_a
select test.expect_error($q$select * from public.claim_next_command('22222222-0000-0000-0000-000000000001')$q$, '42501');
:as_device_b
select test.expect_error($q$select * from public.claim_next_command('22222222-0000-0000-0000-000000000001')$q$, '42501');
:as_device_a
do $$ declare r public.commands; begin
  select * into r from public.claim_next_command('22222222-0000-0000-0000-000000000001');
  assert r.cseq = 1 and r.status = 'claimed' and r.attempts = 1 and r.claimed_at is not null, 'first claim gets cseq 1';
  assert (select count(*) from public.claim_next_command('22222222-0000-0000-0000-000000000001')) = 0,
    'nothing else while cseq 1 is in flight';
end $$;

\echo 'H5 progress: allowed moves only; repeats are no-ops; acked frees the slot'
:as_owner_a
select test.expect_error($q$select public.command_progress(test.cmd(1), 'sent')$q$, '42501');
:as_device_a
do $$ declare r public.commands; begin
  r := public.command_progress(test.cmd(1), 'sent');
  assert r.status = 'sent' and r.sent_at is not null, 'claimed -> sent';
  r := public.command_progress(test.cmd(1), 'sent');
  assert r.status = 'sent', 'a repeat is a no-op';
end $$;
select test.expect_error($q$select public.command_progress(test.cmd(1), 'queued')$q$, '22023');
select test.expect_error($q$select public.command_progress(test.cmd(2), 'acked')$q$, '22023');
do $$ declare r public.commands; begin
  r := public.command_progress(test.cmd(1), 'acked');
  assert r.status = 'acked' and r.acked_at is not null, 'sent -> acked';
  begin
    perform public.command_progress(test.cmd(1), 'sent');
    raise exception 'acked -> sent was allowed';
  exception when sqlstate '22023' then null;
  end;
  select * into r from public.claim_next_command('22222222-0000-0000-0000-000000000001');
  assert r.cseq = 2, 'an acked command is no longer in flight, so cseq 2 is next';
  r := public.command_progress(test.cmd(1), 'done', null, '{"ok": true}');
  assert r.status = 'done' and r.finished_at is not null and r.result = '{"ok": true}', 'acked -> done with a result';
end $$;
select test.expect_error($q$select public.command_progress(test.cmd(1), 'failed')$q$, '22023');
select test.expect_error($q$select public.command_progress(test.cmd(1), 'sent')$q$, '22023');

\echo 'H6 lease: an in-flight command is handed out again, same cseq, once its lease is old'
:as_device_a
do $$ begin
  assert (select count(*) from public.claim_next_command('22222222-0000-0000-0000-000000000001')) = 0, 'lease still fresh';
end $$;
:as_admin
update public.commands set claimed_at = now() - interval '1 hour' where id = test.cmd(2);
:as_device_a
do $$ declare r public.commands; begin
  select * into r from public.claim_next_command('22222222-0000-0000-0000-000000000001');
  assert r.cseq = 2 and r.attempts = 2 and r.status = 'claimed', 'cseq 2 again after the lease expired';
end $$;

\echo 'H7 recover_inflight returns the in-flight command and never claims a new one'
:as_device_a
do $$ declare r public.commands; begin
  select * into r from public.recover_inflight('22222222-0000-0000-0000-000000000001');
  assert r.cseq = 2 and r.attempts = 3, 'the restarted companion gets cseq 2 back';
  perform public.command_progress(test.cmd(2), 'failed', 'E_BUSY');
  assert (select count(*) from public.recover_inflight('22222222-0000-0000-0000-000000000001')) = 0, 'nothing in flight';
  assert (select status from public.commands where id = test.cmd(3)) = 'queued', 'cseq 3 was not claimed';
end $$;
:as_owner_b
select test.expect_error($q$select * from public.recover_inflight('22222222-0000-0000-0000-000000000001')$q$, '42501');

\echo 'H8 owners cancel queued commands only'
:as_device_a
select test.expect_error($q$select public.cancel_command(test.cmd(3))$q$, '42501');
:as_owner_b
select test.expect_error($q$select public.cancel_command('00000000-0000-0000-0000-000000000000')$q$, '42501');
:as_owner_a
do $$ declare r public.commands; begin
  r := public.cancel_command(test.cmd(3));
  assert r.status = 'cancelled' and r.finished_at is not null, 'queued -> cancelled';
end $$;
select test.expect_error($q$select public.cancel_command(test.cmd(3))$q$, '22023');
select test.expect_error($q$select public.cancel_command(test.cmd(1))$q$, '22023');

\echo 'H9 what a command says is immutable, even for the database owner'
:as_admin
select test.expect_error($q$update public.commands set verb = 'cancel' where id = test.cmd(1)$q$, '42501');
select test.expect_error($q$update public.commands set cseq = 50 where id = test.cmd(1)$q$, '42501');
select test.expect_error($q$update public.commands set args = '["x"]' where id = test.cmd(1)$q$, '42501');

\echo 'H10 devices report status through bot_report; nobody writes epoch or ownership directly'
:as_device_a
select public.bot_report('22222222-0000-0000-0000-000000000001', 'ready', '0.1.0', 'k3f9a1', '2.105');
select test.expect_error($q$update public.bots set status = 'busy'$q$, '42501');
select test.expect_error($q$update public.bots set owner_id = 'dddddddd-0000-0000-0000-000000000003'$q$, '42501');
:as_device_b
select test.expect_error($q$select public.bot_report('22222222-0000-0000-0000-000000000001', 'crashed', 'x', 'x')$q$, '42501');
:as_owner_a
do $$ declare b public.bots; begin
  select * into b from public.bots where id = '22222222-0000-0000-0000-000000000001';
  assert b.status = 'ready' and b.script_version = '0.1.0' and b.boot_id = 'k3f9a1' and b.archhud_version = '2.105'
    and b.last_seen is not null, 'the owner sees what the device reported';
end $$;
select test.expect_error($q$update public.bots set epoch = 7$q$, '42501');
select test.expect_error($q$update public.bots set status = 'offline'$q$, '42501');
do $$ declare before timestamptz; after timestamptz; begin
  select updated_at into before from public.bots where short_id = 'hauler-1';
  update public.bots set host = 'vm-01' where short_id = 'hauler-1';
  select updated_at into after from public.bots where short_id = 'hauler-1';
  assert after > before, 'updated_at moves on update';
end $$;

\echo 'H11 sync_epoch: a bot ahead of the hub moves the hub to a new epoch'
:as_owner_a
insert into public.commands (bot_id, verb) values ('22222222-0000-0000-0000-000000000001', 'ping');
:as_owner_b
select test.expect_error($q$select public.sync_epoch('22222222-0000-0000-0000-000000000001', 1, 1)$q$, '42501');
:as_device_a
do $$ declare r public.commands; begin
  assert public.sync_epoch('22222222-0000-0000-0000-000000000001', 0, 0) = 1, 'a fresh bot changes nothing';
  assert public.sync_epoch('22222222-0000-0000-0000-000000000001', 1, 3) = 1, 'a bot behind the hub changes nothing';
  assert public.sync_epoch('22222222-0000-0000-0000-000000000001', 1, 57) = 2, 'a bot ahead moves the hub to epoch 2';
  assert (select status || ':' || error from public.commands where id = test.cmd(4)) = 'cancelled:epoch changed',
    'queued commands of the old epoch are cancelled';
  assert public.sync_epoch('22222222-0000-0000-0000-000000000001', 1, 57) = 2, 'the same report again changes nothing';
end $$;
:as_owner_a
insert into public.commands (bot_id, verb) values ('22222222-0000-0000-0000-000000000001', 'ping');
do $$ begin
  assert exists (select 1 from public.commands where id = test.cmd(1, 2)), 'the next command is 2.1';
  assert (select epoch from public.bots where short_id = 'hauler-1') = 2, 'bots.epoch follows';
  assert (select count(*) from public.events where kind = 'epoch_changed') = 1, 'the owner sees an epoch_changed event';
end $$;
:as_device_a
do $$ begin
  assert public.sync_epoch('22222222-0000-0000-0000-000000000001', 5, 1) = 6, 'a bot in a later epoch moves the hub past it';
end $$;
:as_owner_b
do $$ begin assert (select count(*) from public.events) = 0, 'owner B sees no events of A'; end $$;

\echo 'H12 events belong to the bot owner, or to whoever wrote a bot-less event'
:as_device_a
insert into public.events (bot_id, kind, data) values ('22222222-0000-0000-0000-000000000001', 'skill_state', '{"to": "travel"}');
select test.expect_error($q$insert into public.events (bot_id, kind) values ('22222222-0000-0000-0000-000000000002', 'x')$q$, '42501');
select test.expect_error($q$insert into public.events (owner_id, kind) values ('bbbbbbbb-0000-0000-0000-000000000002', 'x')$q$, '42501');
:as_owner_a
insert into public.events (kind, severity, data) values ('incident', 2, '{}');
do $$ begin
  assert (select count(*) from public.events) = 4, 'A sees the device''s event, its own and both epoch events';
  assert (select bool_and(owner_id = 'aaaaaaaa-0000-0000-0000-000000000001') from public.events), 'all owned by A';
end $$;
:as_owner_b
do $$ begin assert (select count(*) from public.events) = 0, 'owner B still sees nothing'; end $$;

\echo 'H13 devices write state and telemetry for their own bot; owners only read them'
:as_device_a
insert into public.bot_state (bot_id, wx, wy, wz, speed_kmh, autopilot)
values ('22222222-0000-0000-0000-000000000001', 1, 2, 3, 18, 'manual')
on conflict (bot_id) do update set speed_kmh = excluded.speed_kmh;
insert into public.bot_state (bot_id, speed_kmh) values ('22222222-0000-0000-0000-000000000001', 20)
on conflict (bot_id) do update set speed_kmh = excluded.speed_kmh;
insert into public.telemetry (bot_id, data) values ('22222222-0000-0000-0000-000000000001', '{"v": 18}');
select test.expect_error($q$insert into public.telemetry (bot_id, data) values ('22222222-0000-0000-0000-000000000002', '{}')$q$, '42501');
:as_owner_a
do $$ begin
  assert (select speed_kmh from public.bot_state) = 20, 'the owner reads the latest state';
  assert (select count(*) from public.telemetry) = 1, 'and the telemetry';
end $$;
do $$ declare n bigint; begin
  update public.bot_state set speed_kmh = 0;
  get diagnostics n = row_count;
  assert n = 0, 'the owner cannot change bot_state (no rows match an update policy)';
end $$;
select test.expect_error($q$insert into public.telemetry (bot_id, data) values ('22222222-0000-0000-0000-000000000001', '{}')$q$, '42501');
:as_owner_b
do $$ begin
  assert (select count(*) from public.bot_state) = 0 and (select count(*) from public.telemetry) = 0, 'B sees none';
end $$;

\echo 'H14 command_seq is closed to every API role'
:as_owner_a
select test.expect_error($q$select * from public.command_seq$q$, '42501');
:as_device_a
select test.expect_error($q$update public.command_seq set next = 1$q$, '42501');

\echo 'H15 deleting a bot keeps its goals, without the bot'
:as_owner_a
insert into public.goals (bot_id, title) values ('22222222-0000-0000-0000-000000000001', 'haul ore');
delete from public.bots where short_id = 'hauler-1';
do $$ begin
  assert (select count(*) from public.goals where bot_id is null) = 1, 'the goal stays, with bot_id null';
  assert (select count(*) from public.commands) = 0, 'the bot''s commands are gone';
end $$;

\echo 'H16 a run command''s job_id is always its job argument'
:as_owner_b
insert into public.commands (bot_id, verb, args) values ('22222222-0000-0000-0000-000000000002', 'run', '["goto", "j_b1", "pos=0,2,1,2,3"]');
insert into public.commands (bot_id, verb, args, job_id)
values ('22222222-0000-0000-0000-000000000002', 'run', '["goto", "j_b2"]', 'j_other');
do $$ begin
  assert (select string_agg(job_id, ',' order by cseq) from public.commands) = 'j_b1,j_b2', 'job_id follows args[1]';
end $$;
select test.expect_error($q$insert into public.commands (bot_id, verb, args) values ('22222222-0000-0000-0000-000000000002', 'run', '["goto", "bad job"]')$q$, '23514');

\echo 'H17 platform wiring: RLS everywhere, realtime tables, retention jobs'
:as_admin
do $$ begin
  assert not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                      where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
    'row level security is on for every table in public';
  assert (select string_agg(tablename, ',' order by tablename) from pg_publication_tables
           where pubname = 'supabase_realtime') = 'bot_state,bots,commands,events,goals', 'realtime tables';
  assert (select string_agg(jobname || ' ' || schedule, ', ' order by jobname) from cron.job)
    = 'dufleet-commands-retention 45 3 * * *, dufleet-events-retention 30 3 * * *, dufleet-telemetry-retention 15 * * * *',
    'three retention jobs';
  assert (select bool_and(command like 'delete from public.%') from cron.job), 'each job deletes old rows';
  assert not exists (select 1 from information_schema.routine_privileges
                      where routine_schema = 'public' and grantee in ('anon', 'PUBLIC')),
    'no function in public is executable by anon or PUBLIC';
end $$;

\echo 'H18 devices queue resend for their own bot only, reusing one that already covers it'
-- Bot 1 went in H15: this runs on owner B's bot and device B.
:as_device_b
select public.request_resend('22222222-0000-0000-0000-000000000002', 40);
select public.request_resend('22222222-0000-0000-0000-000000000002', 45);
do $$ begin
  assert (select count(*) from public.commands where verb = 'resend') = 1, 'from 40 covers 45';
  assert (select args = '["40"]' and created_by = 'companion' and status = 'queued' and cseq > 0
            from public.commands where verb = 'resend'), 'numbered like any command';
end $$;
select public.request_resend('22222222-0000-0000-0000-000000000002', 30);
do $$ begin
  assert (select count(*) from public.commands where verb = 'resend') = 2, 'from 30 needs its own';
end $$;
select test.expect_error($q$select public.request_resend('22222222-0000-0000-0000-000000000002', -1)$q$, '22023');
select test.expect_error($q$select public.request_resend('22222222-0000-0000-0000-000000000002', 4294967296)$q$, '22023');
:as_device_a
select test.expect_error($q$select public.request_resend('22222222-0000-0000-0000-000000000002', 1)$q$, '42501');
:as_owner_b
select test.expect_error($q$select public.request_resend('22222222-0000-0000-0000-000000000002', 1)$q$, '42501');
:as_anon
select test.expect_error($q$select public.request_resend('22222222-0000-0000-0000-000000000002', 1)$q$, '42501');

\echo 'H19 the skills registry: everyone signed in reads it, nobody writes it, a re-seed keeps the counts'
:as_device_b
do $$ begin
  assert (select version = '1' and args_schema -> 'required' = '["pos"]'
                 and args_schema -> 'properties' ? 'tol' and jsonb_array_length(preconditions) > 0
            from public.skills where name = 'goto'), 'goto is registered with its schema';
  assert (select count(*) from public.skills) = 1, 'only implemented skills';
end $$;
select test.expect_error($q$insert into public.skills (name, version, args_schema, description) values ('x', '1', '{}', 'x')$q$, '42501');
select test.expect_error($q$update public.skills set description = 'x'$q$, '42501');
:as_anon
select test.expect_error($q$select count(*) from public.skills$q$, '42501');
:as_admin
update public.skills set success_count = 3, description = 'stale' where name = 'goto';
insert into public.skills (name, version, args_schema, description) values ('patrol', '0', '{}', 'retired');
\ir ../seed/skills.sql
do $$ begin
  assert (select success_count = 3 and description <> 'stale' from public.skills where name = 'goto'),
    'a re-seed updates the row and keeps its counts';
  assert not exists (select 1 from public.skills where name = 'patrol'), 'skills not in skills.json go';
end $$;

\echo 'all hub scenarios passed'
