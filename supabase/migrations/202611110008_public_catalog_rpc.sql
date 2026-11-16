-- Public catalog RPC: expose only safe catalog fields and rental time windows.
-- Customer names, phone numbers, payment details, and private inventory fields are never returned.

begin;

create or replace function public.get_public_catalog()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $function$
  select jsonb_build_object(
    'units',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'unit_id', u.id,
          'unit_code', u.unit_code,
          'product_id', p.id,
          'product_name', p.name,
          'connectors', u.connectors,
          'condition', u.condition,
          'operational_status', u.operational_status,
          'rates', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'duration_hours', pr.duration_hours,
                'price', pr.price
              )
              order by pr.duration_hours
            )
            from public.product_rates pr
            where pr.product_id = p.id
              and pr.is_active is true
          ), '[]'::jsonb)
        )
        order by p.name, u.unit_code
      )
      from public.units u
      join public.products p on p.id = u.product_id
      where p.is_active is true
        and u.operational_status <> 'inactive'
    ), '[]'::jsonb),
    'rentals',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'unit_id', r.unit_id,
          'start_at', r.start_at,
          'end_at', r.end_at
        )
        order by r.start_at
      )
      from public.rentals r
      where r.status in ('reserved', 'confirmed', 'ongoing')
        and r.end_at > now()
    ), '[]'::jsonb)
  );
$function$;

revoke all on function public.get_public_catalog() from public;
grant execute on function public.get_public_catalog() to anon, authenticated;

commit;
