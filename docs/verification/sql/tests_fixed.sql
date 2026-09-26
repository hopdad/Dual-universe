-- The same scenarios after 0005_fixes.sql. Every block should now show the safe outcome.
\set QUIET 1
\pset footer off
\pset tuples_only on
insert into auth.users(id,email) values
 ('aaaaaaaa-0000-0000-0000-000000000001','owner-a'),('bbbbbbbb-0000-0000-0000-000000000002','owner-b'),('dddddddd-0000-0000-0000-000000000003','device-of-a');
set role authenticated; set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001'; set request.jwt.claim.role = 'authenticated';
insert into servers(id, owner_id, name, url) values ('11111111-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','srv-a','https://a');
insert into bots(id, owner_id, server_id, short_id, device_user_id) values ('22222222-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000001','bot01','dddddddd-0000-0000-0000-000000000003');
insert into commands(bot_id, verb) values ('22222222-0000-0000-0000-000000000001','ping'),('22222222-0000-0000-0000-000000000001','status');
\echo 'F1 cseq still assigned 1,2:'
select string_agg(cseq::text, ',' order by cseq) from commands;
set request.jwt.claim.sub = 'dddddddd-0000-0000-0000-000000000003';
\echo 'F2 claim -> cseq 1; second claim while 1 in flight -> 0 rows:'
select cseq from claim_next_command('22222222-0000-0000-0000-000000000001');
select count(*) || ' row(s)' from claim_next_command('22222222-0000-0000-0000-000000000001');
update commands set status = 'done' where cseq = 1;
\echo 'F3 after cseq 1 done -> claim gives 2; then empty queue -> 0 rows:'
select cseq from claim_next_command('22222222-0000-0000-0000-000000000001');
update commands set status = 'done' where cseq = 2;
select count(*) || ' row(s)' from claim_next_command('22222222-0000-0000-0000-000000000001');
\set ON_ERROR_STOP 0
\echo 'F4 other tenant / anon on command_seq (expect permission denied):'
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';
select count(*) from command_seq;
reset role; set role anon; select count(*) from command_seq;
reset role; set role authenticated;
\echo 'F5 client-supplied cseq is ignored (expect 3, not 999):'
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
insert into commands(bot_id, cseq, verb) values ('22222222-0000-0000-0000-000000000001', 999, 'ping');
select max(cseq) from commands;
\echo 'F6 rewriting cseq/verb after insert (expect immutable error):'
update commands set verb = 'cancel' where cseq = 3;
\echo 'F7 device takes ownership via UPDATE (expect 0 rows) and via RPC for status (expect ok):'
set request.jwt.claim.sub = 'dddddddd-0000-0000-0000-000000000003';
with u as (update bots set owner_id = 'dddddddd-0000-0000-0000-000000000003' returning 1) select count(*) || ' row(s) updated' from u;
select 'rpc: ' || coalesce(bot_report('22222222-0000-0000-0000-000000000001','ready','0.1.0','k3f9')::text, 'ok');
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
select 'owner sees bot status: ' || status || ', version ' || script_version from bots;
\echo 'F8 events isolated per owner (expect B sees 0):'
insert into events(bot_id, kind, data) values (null, 'incident', '{}');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';
select 'B sees: ' || count(*) from events;
\echo 'F9 deleting a bot with goals (expect ok, goal keeps row with null bot):'
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
insert into goals(owner_id, bot_id, title) values ('aaaaaaaa-0000-0000-0000-000000000001','22222222-0000-0000-0000-000000000001','haul');
delete from bots where short_id = 'bot01';
select 'goals left: ' || count(*) || ', bot_id null: ' || bool_and(bot_id is null) from goals;
