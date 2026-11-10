-- Prevent overlapping active rentals for the same microphone unit.
-- The per-unit transaction advisory lock closes the race between simultaneous checkouts.

begin;

create or replace function public.prevent_rental_schedule_overlap()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  if new.status in ('reserved','confirmed','ongoing') then
    perform pg_advisory_xact_lock(hashtextextended(new.unit_id::text, 0));

    if exists (
      select 1
      from public.rentals r
      where r.unit_id = new.unit_id
        and r.id is distinct from new.id
        and r.status in ('reserved','confirmed','ongoing')
        and r.start_at < new.end_at
        and r.end_at > new.start_at
    ) then
      raise exception 'Jadwal unit sudah bertabrakan dengan penyewaan aktif lain.'
        using errcode = '23P01';
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists rentals_prevent_schedule_overlap on public.rentals;
create trigger rentals_prevent_schedule_overlap
before insert or update of unit_id, start_at, end_at, status
on public.rentals
for each row
execute function public.prevent_rental_schedule_overlap();

commit;
