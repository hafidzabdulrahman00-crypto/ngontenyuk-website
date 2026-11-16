-- Speed up per-unit overlap checks for active rental schedules.
-- This partial index excludes completed/cancelled history from the hot path.

begin;

create index if not exists rentals_active_unit_schedule_idx
  on public.rentals (unit_id, start_at, end_at)
  where status in ('reserved','confirmed','ongoing');

commit;
