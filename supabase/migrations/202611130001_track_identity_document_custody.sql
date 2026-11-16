-- Records physical KTP/KTM custody consistently with the mandatory POS/RMS attestation.
-- A completed return also records that the held identity document was returned.
-- Existing historical rentals are intentionally left unchanged.

begin;
CREATE OR REPLACE FUNCTION public.create_pos_checkout(p_checkout_id uuid, p_customer_name text, p_customer_phone text, p_items jsonb, p_payment_method text, p_cash_received boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    from jsonb_array_elements(p_items) as items(item)
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
    if not exists (
      select 1 from public.products p
      where p.id = v_unit.product_id and p.is_active = true
    ) then
      raise exception 'Produk untuk unit % sudah tidak aktif.', v_unit.unit_code;
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
      identity_document_type, identity_deposit_status, identity_received_at,
      tenant_signature_data, staff_signature_data, agreement_signed_at
    )
    values (
      v_code, v_customer_id, v_unit.id, v_start, v_end,
      v_price, 0, 'reserved',
      true, true, true,
      v_item->>'identity_document_type', 'held', now(),
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

CREATE OR REPLACE FUNCTION public.create_rms_rental(p_request_id uuid, p_customer_name text, p_customer_phone text, p_unit_id uuid, p_start_at timestamp with time zone, p_end_at timestamp with time zone, p_identity_document_type text, p_tenant_signature_data text, p_staff_signature_data text, p_identity_verified boolean, p_agreement_signed boolean, p_guarantee_explained boolean, p_notes text, p_payment_method text DEFAULT NULL::text, p_cash_received boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := auth.uid();
  v_role text;
  v_name text := nullif(trim(coalesce(p_customer_name, '')), '');
  v_phone text := nullif(trim(coalesce(p_customer_phone, '')), '');
  v_hash text;
  v_existing public.rms_rental_requests%rowtype;
  v_customer_id uuid;
  v_unit public.units%rowtype;
  v_code text;
  v_hours integer;
  v_remaining integer;
  v_price numeric := 0;
  v_rate numeric;
  v_rental_id uuid;
  v_payment_id uuid;
  v_response jsonb;
  v_is_cashier boolean;
begin
  if v_user is null then raise exception 'Sesi login diperlukan.'; end if;
  v_role := coalesce(public.current_user_role(), '');
  if v_role not in ('owner','admin','staff') then raise exception 'Akses Staff RMS ditolak.'; end if;
  if p_request_id is null then raise exception 'ID permintaan wajib diisi.'; end if;
  if v_name is null or char_length(v_name) > 120 then raise exception 'Nama pelanggan wajib diisi (maksimal 120 karakter).'; end if;
  if v_phone is null or v_phone !~ '^[+0-9][0-9+() .-]{7,28}$' then raise exception 'Nomor WhatsApp pelanggan tidak valid.'; end if;
  if p_unit_id is null then raise exception 'Unit microphone wajib dipilih.'; end if;
  if p_start_at is null or p_end_at is null or p_start_at < now() - interval '1 minute' or p_end_at <= p_start_at then
    raise exception 'Jadwal rental tidak valid atau sudah lewat.';
  end if;
  if extract(epoch from (p_end_at - p_start_at)) < 4 * 3600 then raise exception 'Durasi minimum penyewaan adalah 4 jam.'; end if;
  if p_identity_document_type not in ('KTP','KTM') then raise exception 'Pilih jenis identitas KTP atau KTM.'; end if;
  if p_identity_verified is distinct from true or p_agreement_signed is distinct from true or p_guarantee_explained is distinct from true then
    raise exception 'Verifikasi identitas, persetujuan sewa, dan penjelasan garansi wajib lengkap.';
  end if;
  if p_tenant_signature_data is null or p_staff_signature_data is null
     or length(p_tenant_signature_data) > 120000 or length(p_staff_signature_data) > 120000
     or p_tenant_signature_data not like 'data:image/jpeg;base64,%'
     or p_staff_signature_data not like 'data:image/jpeg;base64,%' then
    raise exception 'Kedua tanda tangan JPEG wajib diisi dengan ukuran yang valid.';
  end if;
  if length(coalesce(p_notes,'')) > 2000 then raise exception 'Catatan rental maksimal 2000 karakter.'; end if;

  v_is_cashier := v_role in ('owner','admin');
  if v_is_cashier then
    if p_payment_method is null or p_payment_method not in ('cash','qris_manual') then
      raise exception 'Owner/Admin harus memilih Tunai atau QRIS manual.';
    end if;
    if p_payment_method = 'cash' and p_cash_received is distinct from true then
      raise exception 'Pembayaran tunai harus dikonfirmasi telah diterima.';
    end if;
    if p_payment_method = 'qris_manual' and coalesce(p_cash_received,false) then
      raise exception 'Konfirmasi uang tunai tidak berlaku untuk QRIS.';
    end if;
  else
    if p_payment_method is not null or coalesce(p_cash_received,false) then
      raise exception 'Staff membuat reservasi tanpa mencatat pembayaran.';
    end if;
  end if;

  v_hash := md5(jsonb_build_object(
    'customer_name',v_name,'customer_phone',v_phone,'unit_id',p_unit_id,
    'start_at',p_start_at,'end_at',p_end_at,
    'identity_document_type',p_identity_document_type,
    'tenant_signature_data',p_tenant_signature_data,
    'staff_signature_data',p_staff_signature_data,
    'identity_verified',p_identity_verified,'agreement_signed',p_agreement_signed,
    'guarantee_explained',p_guarantee_explained,'notes',p_notes,
    'payment_method',p_payment_method,'cash_received',coalesce(p_cash_received,false)
  )::text);

  insert into public.rms_rental_requests(request_id,created_by,request_hash)
  values(p_request_id,v_user,v_hash) on conflict(request_id) do nothing;
  select * into v_existing from public.rms_rental_requests where request_id=p_request_id for update;
  if v_existing.created_by <> v_user then raise exception 'ID permintaan tidak valid untuk akun ini.'; end if;
  if v_existing.request_hash <> v_hash then raise exception 'ID permintaan sudah dipakai untuk data berbeda. Muat ulang dan buat permintaan baru.'; end if;
  if v_existing.response is not null then return v_existing.response; end if;

  perform pg_advisory_xact_lock(hashtextextended(lower(v_phone),0));
  select c.id into v_customer_id from public.customers c where c.phone=v_phone order by c.created_at limit 1 for update;
  if v_customer_id is null then
    insert into public.customers(name,phone) values(v_name,v_phone) returning id into v_customer_id;
  else
    update public.customers set name=v_name where id=v_customer_id;
  end if;

  select * into v_unit from public.units u where u.id=p_unit_id for update;
  if not found then raise exception 'Unit tidak ditemukan.'; end if;
  if v_unit.operational_status <> 'available' or v_unit.condition not in ('new','good','fair') then
    raise exception 'Unit tidak memenuhi syarat untuk disewakan.';
  end if;
  if not exists(select 1 from public.products p where p.id=v_unit.product_id and p.is_active=true) then
    raise exception 'Produk untuk unit ini sudah tidak aktif.';
  end if;

  v_hours := ceil(extract(epoch from (p_end_at-p_start_at))/3600.0)::integer;
  v_remaining := v_hours;
  while v_remaining >= 24 loop
    select pr.price into v_rate from public.product_rates pr
    where pr.product_id=v_unit.product_id and pr.duration_hours=24 and pr.is_active=true limit 1;
    if not found or v_rate is null or v_rate <= 0 then raise exception 'Tarif paket 24 jam belum tersedia atau tidak valid.'; end if;
    v_price := v_price + v_rate;
    v_remaining := v_remaining - 24;
  end loop;
  if v_remaining > 0 then
    select pr.price into v_rate from public.product_rates pr
    where pr.product_id=v_unit.product_id and pr.duration_hours >= v_remaining and pr.is_active=true
    order by pr.duration_hours asc limit 1;
    if not found or v_rate is null or v_rate <= 0 then raise exception 'Tarif untuk sisa durasi rental belum tersedia atau tidak valid.'; end if;
    v_price := v_price + v_rate;
  end if;
  if v_price <= 0 then raise exception 'Harga rental harus lebih dari nol.'; end if;

  v_code := 'NY-' || to_char(now() at time zone 'Asia/Jakarta','YYYYMMDD') || '-' ||
    upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));

  insert into public.rentals(
    rental_code,customer_id,unit_id,start_at,end_at,rental_price,deposit_amount,
    identity_verified,agreement_signed,guarantee_explained,status,notes,
    identity_document_type,identity_deposit_status,identity_received_at,identity_verified_by,identity_verified_at,
    tenant_signature_data,staff_signature_data,agreement_signed_by,agreement_signed_at,
    guarantee_explained_by,guarantee_explained_at
  ) values(
    v_code,v_customer_id,v_unit.id,p_start_at,p_end_at,v_price,0,
    true,true,true,'reserved',nullif(trim(coalesce(p_notes,'')),''),
    p_identity_document_type,'held',now(),v_user,now(),
    p_tenant_signature_data,p_staff_signature_data,v_user,now(),
    v_user,now()
  ) returning id into v_rental_id;

  if v_is_cashier then
    insert into public.payments(rental_id,amount,payment_type,payment_method,payment_status)
    values(v_rental_id,v_price,'rental',p_payment_method,'pending') returning id into v_payment_id;
    if p_payment_method='cash' then
      update public.payments set payment_status='paid' where id=v_payment_id;
    end if;
  end if;

  v_response := jsonb_build_object(
    'id',v_rental_id,'rental_code',v_code,'unit_id',v_unit.id,
    'start_at',p_start_at,'end_at',p_end_at,'rental_price',v_price,
    'payment_id',v_payment_id,
    'payment_status',case when not v_is_cashier then null when p_payment_method='cash' then 'paid' else 'pending' end
  );
  update public.rms_rental_requests set response=v_response where request_id=p_request_id;
  return v_response;
end;
$function$;

CREATE OR REPLACE FUNCTION public.complete_rental_return(p_rental_id uuid, p_return_condition text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_rental public.rentals%rowtype;
  v_unit public.units%rowtype;
  v_role text;
  v_notes text := nullif(trim(coalesce(p_notes,'')),'');
  v_new_status text;
begin
  if auth.uid() is null then
    raise exception 'Sesi login diperlukan.';
  end if;

  v_role := coalesce(public.current_user_role(),'');
  if v_role not in ('owner','admin','staff') then
    raise exception 'Akses pengembalian ditolak.';
  end if;

  if p_return_condition not in ('new','good','fair','damaged') then
    raise exception 'Kondisi pengembalian tidak valid.';
  end if;
  if v_notes is not null and char_length(v_notes)>500 then
    raise exception 'Catatan pengembalian maksimal 500 karakter.';
  end if;

  select * into v_rental
  from public.rentals
  where id=p_rental_id
  for update;

  if not found then
    raise exception 'Rental tidak ditemukan.';
  end if;
  if v_rental.status <> 'ongoing' then
    raise exception 'Pengembalian hanya dapat dicatat untuk rental yang sedang berlangsung.';
  end if;

  select * into v_unit
  from public.units
  where id=v_rental.unit_id
  for update;

  if not found then
    raise exception 'Unit rental tidak ditemukan.';
  end if;

  v_new_status := case when p_return_condition='damaged' then 'maintenance' else 'available' end;

  update public.rentals
  set status='completed',
      identity_deposit_status='returned',
      identity_returned_at=coalesce(identity_returned_at,now())
  where id=p_rental_id;

  update public.units
  set condition=p_return_condition,
      operational_status=v_new_status
  where id=v_unit.id;

  insert into public.rental_returns(rental_id,unit_id,returned_by,return_condition,notes)
  values(p_rental_id,v_unit.id,auth.uid(),p_return_condition,v_notes);

  return jsonb_build_object(
    'rental_id',p_rental_id,
    'rental_status','completed',
    'unit_id',v_unit.id,
    'unit_code',v_unit.unit_code,
    'condition',p_return_condition,
    'operational_status',v_new_status,
    'returned_at',now()
  );
end;
$function$;
commit;
