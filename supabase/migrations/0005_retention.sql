-- Retention through pg_cron (Supabase Cron). Where pg_cron is missing the migration
-- still applies, with a warning, and nothing is deleted.
do $$
begin
  if to_regnamespace('cron') is null
     and exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
  end if;
  if to_regnamespace('cron') is null then
    raise warning 'pg_cron is not available: telemetry, events and commands are not pruned';
    return;
  end if;
  perform cron.schedule('dufleet-telemetry-retention', '15 * * * *',
    $job$delete from public.telemetry where ts < now() - interval '7 days'$job$);
  perform cron.schedule('dufleet-events-retention', '30 3 * * *',
    $job$delete from public.events where ts < now() - interval '30 days' and severity < 2$job$);
  perform cron.schedule('dufleet-commands-retention', '45 3 * * *',
    $job$delete from public.commands where status in ('done', 'failed', 'failed_delivery', 'cancelled')
         and updated_at < now() - interval '90 days'$job$);
end $$;
