-- A small stand-in for the Supabase platform, so the migrations and scenarios run on
-- plain PostgreSQL: the API roles, auth.users, auth.uid(), the realtime publication,
-- Supabase's default grants, and a fake pg_cron that only records schedules.
-- Test-only; never apply this to a Supabase project.
do $$
begin
  if not exists (select from pg_roles where rolname = 'anon') then
    create role anon nologin;
    create role authenticated nologin;
    create role service_role nologin bypassrls;
  end if;
end $$;

create schema auth;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;

-- Supabase's defaults: the API roles get everything; row level security restricts them.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

set client_min_messages = error; -- plain PostgreSQL warns that wal_level is not logical
create publication supabase_realtime;
reset client_min_messages;

create schema cron;
create table cron.job (jobid bigserial primary key, jobname text unique, schedule text, command text);
create function cron.schedule(job_name text, schedule text, command text) returns bigint language sql as $$
  insert into cron.job (jobname, schedule, command) values (job_name, schedule, command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command
  returning jobid
$$;
