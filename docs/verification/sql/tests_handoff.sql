-- Behaviour tests against the handoff schema as written. Each block prints the observed result; see docs/verification.md for expected vs actual.
\set QUIET 1
\pset footer off
\pset tuples_only on
insert into auth.users(id,email) values
 ('aaaaaaaa-0000-0000-0000-000000000001','owner-a'),
 ('bbbbbbbb-0000-0000-0000-000000000002','owner-b'),
 ('dddddddd-0000-0000-0000-000000000003','device-of-a');
-- owner A creates a server and a bot whose device user is D
set role authenticated; set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001'; set request.jwt.claim.role = 'authenticated';
insert into servers(id, owner_id, name, url) values ('11111111-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','srv-a','https://a');
insert into bots(id, owner_id, server_id, short_id, device_user_id) values ('22222222-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','11111111-0000-0000-0000-000000000001','bot01','dddddddd-0000-0000-0000-000000000003');
insert into commands(bot_id, verb) values ('22222222-0000-0000-0000-000000000001','ping'),('22222222-0000-0000-0000-000000000001','status'),('22222222-0000-0000-0000-000000000001','ping');
\echo 'T1 cseq assigned by trigger (expect 1,2,3):'
select string_agg(cseq::text, ',' order by cseq) from commands;

set request.jwt.claim.sub = 'dddddddd-0000-0000-0000-000000000003';
\echo 'T2 device claims first command (expect cseq 1 claimed):'
select cseq, status from claim_next_command('22222222-0000-0000-0000-000000000001');
\echo 'T3 device claims again while cseq 1 is still un-acked (spec: one un-acked at a time; DB hands out cseq 2):'
select cseq, status from claim_next_command('22222222-0000-0000-0000-000000000001');
select cseq from claim_next_command('22222222-0000-0000-0000-000000000001');
\echo 'T4 empty queue: rows returned by select * from claim_next_command (expect 0, a SETOF would give 0):'
select count(*) || ' row(s); id is null = ' || bool_and(id is null)::text from claim_next_command('22222222-0000-0000-0000-000000000001');

\echo 'T5 other tenant B reads/modifies command_seq (no RLS on that table):'
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';
select 'B sees command_seq rows: ' || count(*) from command_seq;
with u as (update command_seq set next = 1 returning 1) select 'B reset rows: ' || count(*) from u;
reset role; set role anon; reset request.jwt.claim.sub;
select 'anon (no login) sees command_seq rows: ' || count(*) from command_seq;
reset role; set role authenticated; set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
\echo 'T5b owner A now queues a command after B reset the sequence:'
\set ON_ERROR_STOP 0
insert into commands(bot_id, verb) values ('22222222-0000-0000-0000-000000000001','ping');
\echo 'T6 events with bot_id null are shared across tenants:'
insert into events(bot_id, kind, data) values (null, 'incident', '{"note":"owner A private"}');
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';
select 'B sees A''s null-bot events: ' || count(*) from events where bot_id is null;
with d as (delete from events where bot_id is null returning 1) select 'B deleted: ' || count(*) from d;
\echo 'T7 device user rewrites bots.owner_id (no WITH CHECK / column limits on bots_device_update):'
set request.jwt.claim.sub = 'dddddddd-0000-0000-0000-000000000003';
with u as (update bots set owner_id = 'dddddddd-0000-0000-0000-000000000003' where short_id = 'bot01' returning 1) select 'device rows updated: ' || count(*) from u;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
select 'owner A still sees bots: ' || count(*) from bots;
\echo 'T8 client-supplied cseq bypasses the sequence trigger:'
set request.jwt.claim.sub = 'dddddddd-0000-0000-0000-000000000003';
insert into commands(bot_id, cseq, verb) values ('22222222-0000-0000-0000-000000000001', 999, 'ping');
select 'max cseq now: ' || max(cseq) from commands;
\echo 'T9 deleting a bot referenced by a goal:'
insert into goals(owner_id, bot_id, title) values ('dddddddd-0000-0000-0000-000000000003','22222222-0000-0000-0000-000000000001','haul');
delete from bots where short_id = 'bot01';
