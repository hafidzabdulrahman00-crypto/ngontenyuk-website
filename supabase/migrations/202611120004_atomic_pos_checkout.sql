-- NgontenYuk.co: atomic, idempotent POS checkout.
-- All customer/rental/payment rows are committed in one transaction.
-- This migration changes schema/functions only; it does not create business records.

begin;

create table if not exists public.pos_checkout_requests (
  checkout_id uuid primary key,
  created_by uuid not null references auth.users(id) on delete restrict,
  request_hash text not null,
  response jsonb,
  created_at timestamptz not null default now()
);

alter table public.pos_checkout_requests enable row level security;
revoke all on table public.pos_checkout_requests from public, anon, authenticated;

create or replace function public.create_pos_checkout(
  p_checkout_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_items jsonb,
  p_payment_method text,
  p_cash_received boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user uuid := auth.uid();
  v_role text;
  v_name text := nullif(trim(coalesce(p_customer_name, '')), '');
  v_phone text := nullif(trim(coalesce(p_customer_phone, '')), '');
  v_hash text;
  v_existing public.pos_checkout_requests%rowtype;
  v_customer_id uuid;
  v_item jsonb;
  v_unit public.units%rowtype;
  v_rental_id uuid;
  v_payment_id uuid;
  v_code text;
  v_start timestamptz;
  v_end timestamptz;
  v_hours integer;
  v_remaining integer;
  v_price numeric;
  v_rate numeric;
  v_total numeric;
  v_response jsonb := '[]'::jsonb;
begin
  if v_user is null then
    raise exception 'Sesi login diperlukan.';
  end if;

  v_role := coalesce(public.current_user_role(), '');
  if v_role not in ('owner', 'admin', 'staff') then
    raise exception 'Akses POS ditolak.';
  end if;

  if p_checkout_id is null then
    raise exception 'ID checkout wajib diisi.';
  end if;
  if v_name is null or char_length(v_name) > 120 then
    raise exception 'Nama pelanggan wajib diisi (maksimal 120 karakter).';
  end if;
  if v_phone is null or v_phone !~ '^[+0-9][0-9+() .-]{7,28}$' then
    raise exception 'Nomor WhatsApp pelanggan tidak valid.';
  end if;
  if p_items is null or jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'Format item checkout tidak valid.';
  end if;
  if jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 20 then
    raise exception 'Checkout harus berisi 1 sampai 20 unit.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_items) item
    group by item->>'unit_id'
    having count(*) > 1
  ) then
    raise exception 'Satu unit hanya boleh dimasukkan sekali dalam satu checkout.';
  end if;
  if p_payment_method is null
     or p_payment_method not in ('cash', 'bank_transfer', 'qris_manual') then
    raise exception 'Metode pembayaran POS tidak valid.';
  end if;
  if p_payment_method = 'cash' and p_cash_received is distinct from true then
    raise exception 'Pembayaran tunai harus dikonfirmasi telah diterima.';
  end if;
  if p_payment_method <> 'cash' and coalesce(p_cash_received, false) then
    raise exception 'Konfirmasi penerimaan tunai tidak berlaku untuk metode ini.';
  end if;

  v_hash := md5(jsonb_build_object(
    'customer_name', v_name,
    'customer_phone', v_phone,
    'items', p_items,
    'payment_method', p_payment_method,
    'cash_received', coalesce(p_cash_received, false)
  )::text);

  insert into public.pos_checkout_requests(checkout_id, created_by, request_hash)
  values (p_checkout_id, v_user, v_hash)
  on conflict (checkout_id) do nothing;

  select * into v_existing
  from public.pos_checkout_requests
  where checkout_id = p_checkout_id
  for update;

  if v_existing.created_by <> v_user then
    raise exception 'ID checkout tidak valid untuk akun ini.';
  end if;
  if v_existing.request_hash <> v_hash then
    raise exception 'ID checkout sudah digunakan untuk data transaksi berbeda. Muat ulang transaksi sebelum mencoba lagi.';
  end if;
  if v_existing.response is not null then
    return v_existing.response;
  end if;

  -- Serialize customer matching by normalized phone to avoid concurrent duplicates.
  perform pg_advisory_xact_lock(hashtextextended(lower(v_phone), 0));

  select c.id into v_customer_id
  from public.customers c
  where c.phone = v_phone
  order by c.created_at
  limit 1
  for update;

  if v_customer_id is null then
    insert into public.customers(name, phone)
    values (v_name, v_phone)
    returning id into v_customer_id;
  else
    update public.customers set name = v_name where id = v_customer_id;
  end if;

  for v_item in select value from jsonb_array_elements(p_items) order by value->>'unit_id'
  loop
    if nullif(v_item->>'unit_id', '') is null
       or nullif(v_item->>'start_at', '') is null
       or nullif(v_item->>'end_at', '') is null
       or coalesce(nullif(v_item->>'identity_document_type', ''), '') not in ('KTP','KTM')
       or nullif(v_item->>'tenant_signature_data', '') is null
       or nullif(v_item->>'staff_signature_data', '') is null then
      raise exception 'Data unit, jadwal, identitas, dan kedua tanda tangan wajib lengkap.';
    end if;

    v_start := (v_item->>'start_at')::timestamptz;
    v_end := (v_item->>'end_at')::timestamptz;
    if v_start < now() - interval '1 minute' or v_end <= v_start then
      raise exception 'Jadwal rental tidak valid atau sudah lewat.';
    end if;

    if length(v_item->>'tenant_signature_data') > 120000
       or length(v_item->>'staff_signature_data') > 120000 then
      raise exception 'Ukuran tanda tangan melebihi batas.';
    end if;

    select * into v_unit
    from public.units u
    where u.id = (v_item->>'unit_id')::uuid
    for update;

    if not found then
      raise exception 'Unit tidak ditemukan.';
    end if;
    if v_unit.operational_status <> 'available'
       or v_unit.condition = 'damaged' then
      raise exception 'Unit % tidak tersedia untuk disewa.', v_unit.unit_code;
    end if;

    -- Recalculate price in the database; never trust a client-supplied amount.
    v_hours := ceil(extract(epoch from (v_end - v_start)) / 3600.0)::integer;
    if v_hours not in (4, 6, 12, 24)
       or extract(epoch from (v_end - v_start)) <> v_hours * 3600 then
      raise exception 'Durasi POS harus tepat 4, 6, 12, atau 24 jam.';
    end if;
    v_remaining := v_hours;
    v_price := 0;

    while v_remaining >= 24 loop
      select pr.price into v_rate
      from public.product_rates pr
      where pr.product_id = v_unit.product_id
        and pr.duration_hours = 24
        and pr.is_active = true
      limit 1;
      if not found or v_rate is null or v_rate <= 0 then
        raise exception 'Tarif paket 24 jam belum tersedia atau tidak valid untuk unit %.', v_unit.unit_code;
      end if;
      v_price := v_price + v_rate;
      v_remaining := v_remaining - 24;
    end loop;

    if v_remaining > 0 then
      select pr.price into v_rate
      from public.product_rates pr
      where pr.product_id = v_unit.product_id
        and pr.duration_hours >= v_remaining
        and pr.is_active = true
      order by pr.duration_hours asc
      limit 1;
      if not found or v_rate is null or v_rate <= 0 then
        raise exception 'Tarif durasi % jam belum tersedia atau tidak valid untuk unit %.', v_remaining, v_unit.unit_code;
      end if;
      v_price := v_price + v_rate;
    end if;

    if v_price <= 0 then
      raise exception 'Harga rental harus lebih dari nol.';
    end if;

    v_code := 'NY-' ||
      to_char(now() at time zone 'Asia/Jakarta', 'YYYYMMDD') || '-' ||
      upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));

    insert into public.rentals (
      rental_code, customer_id, unit_id, start_at, end_at,
      rental_price, deposit_amount, status,
      identity_verified, agreement_signed, guarantee_explained,
      identity_document_type, identity_deposit_status,
      tenant_signature_data, staff_signature_data, agreement_signed_at
    )
    values (
      v_code, v_customer_id, v_unit.id, v_start, v_end,
      v_price, 0, 'reserved',
      true, true, true,
      v_item->>'identity_document_type', 'not_received',
      v_item->>'tenant_signature_data', v_item->>'staff_signature_data', now()
    )
    returning id into v_rental_id;

    insert into public.payments (
      rental_id, amount, payment_type, payment_method, payment_status
    )
    values (
      v_rental_id, v_price, 'rental', p_payment_method, 'pending'
    )
    returning id into v_payment_id;

    if p_payment_method = 'cash' then
      update public.payments
      set payment_status = 'paid'
      where id = v_payment_id;
    end if;

    v_response := v_response || jsonb_build_array(jsonb_build_object(
      'id', v_rental_id,
      'rental_code', v_code,
      'unit_id', v_unit.id,
      'start_at', v_start,
      'end_at', v_end,
      'rental_price', v_price,
      'payment_id', v_payment_id,
      'payment_status', case when p_payment_method = 'cash' then 'paid' else 'pending' end
    ));
  end loop;

  update public.pos_checkout_requests
  set response = v_response
  where checkout_id = p_checkout_id;

  return v_response;
end;
$function$;

revoke all on function public.create_pos_checkout(uuid, text, text, jsonb, text, boolean)
  from public, anon;
grant execute on function public.create_pos_checkout(uuid, text, text, jsonb, text, boolean)
  to authenticated;

commit;
