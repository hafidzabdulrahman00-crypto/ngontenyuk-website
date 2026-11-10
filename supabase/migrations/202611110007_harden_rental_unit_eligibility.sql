-- Harden the rentable-unit trigger:
-- lock the unit row against concurrent status/condition edits and handle NULLs safely.

begin;

create or replace function public.validate_rental_unit_eligibility()
returns trigger
language plpgsql
set search_path = public
as $function$
declare
  v_operational_status text;
  v_condition text;
begin
  if new.status in ('reserved','confirmed','ongoing') then
    select u.operational_status, u.condition
      into v_operational_status, v_condition
    from public.units u
    where u.id = new.unit_id
    for update;

    if not found then
      raise exception 'Unit microphone tidak ditemukan.'
        using errcode = '23503';
    end if;

    if v_operational_status is distinct from 'available'
       or v_condition is null
       or v_condition not in ('new','good','fair') then
      raise exception 'Unit tidak memenuhi syarat untuk disewakan. Periksa status operasional dan kondisi unit.'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$function$;

commit;
