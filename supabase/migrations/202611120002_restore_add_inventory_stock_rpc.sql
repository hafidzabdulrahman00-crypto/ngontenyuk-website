-- NgontenYuk.co: restore the audited inventory RPC to migration history.
-- This migration is safe to re-run. It does not create or modify inventory rows.
-- The function itself only permits Owner/Admin through current_user_role().

begin;

create or replace function public.add_inventory_stock(
  p_product_id uuid,
  p_quantity integer,
  p_purchase_date date default null,
  p_purchase_cost numeric default 0,
  p_condition text default 'good',
  p_connectors text[] default null,
  p_notes text default null
)
returns table(unit_id uuid, unit_code text)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_prefix text;
  v_product_connectors text[];
  v_connectors text[];
  v_next_no integer;
  v_i integer;
begin
  if auth.uid() is null
     or coalesce(public.current_user_role(), '') not in ('owner', 'admin') then
    raise exception 'Akses ditolak';
  end if;

  if p_quantity is null or p_quantity < 1 or p_quantity > 50 then
    raise exception 'Jumlah stok harus antara 1 sampai 50';
  end if;

  if p_purchase_cost is null or p_purchase_cost < 0 then
    raise exception 'Harga modal tidak boleh negatif';
  end if;

  if p_condition is null or p_condition not in ('new', 'good', 'fair', 'damaged') then
    raise exception 'Kondisi unit tidak valid';
  end if;

  select p.unit_prefix, p.connectors
    into v_prefix, v_product_connectors
  from public.products p
  where p.id = p_product_id
    and p.is_active = true
  for update;

  if not found then
    raise exception 'Produk tidak ditemukan atau tidak aktif';
  end if;

  v_connectors := coalesce(p_connectors, v_product_connectors);

  if v_connectors is null or not (v_connectors <@ v_product_connectors) then
    raise exception 'Konektor tidak sesuai dengan produk';
  end if;

  select coalesce(max(regexp_replace(u.unit_code, '^.*-', '')::integer), 0) + 1
    into v_next_no
  from public.units u
  where u.unit_code like v_prefix || '-%';

  for v_i in 1..p_quantity loop
    return query
    insert into public.units (
      product_id, unit_code, connectors, purchase_date, purchase_cost,
      condition, operational_status, notes
    )
    values (
      p_product_id,
      v_prefix || '-' || lpad(v_next_no::text, 3, '0'),
      v_connectors,
      p_purchase_date,
      p_purchase_cost,
      p_condition,
      'available',
      p_notes
    )
    returning units.id, units.unit_code;

    v_next_no := v_next_no + 1;
  end loop;
end;
$function$;

revoke all on function public.add_inventory_stock(uuid, integer, date, numeric, text, text[], text[])
  from public, anon;
grant execute on function public.add_inventory_stock(uuid, integer, date, numeric, text, text[], text[])
  to authenticated;

commit;
