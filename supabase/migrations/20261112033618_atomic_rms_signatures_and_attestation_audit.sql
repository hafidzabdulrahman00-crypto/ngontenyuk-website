-- Atomic RMS signatures, verification audit metadata, and client-side attestation guards.
-- Applied to NgontenYuk Staging as migration 20261112033618.

begin;

alter table public.rentals
  add column if not exists identity_verified_by uuid references auth.users(id) on delete set null,
  add column if not exists identity_verified_at timestamptz,
  add column if not exists agreement_signed_by uuid references auth.users(id) on delete set null,
  add column if not exists guarantee_explained_by uuid references auth.users(id) on delete set null,
  add column if not exists guarantee_explained_at timestamptz;

create or replace function public.guard_rental_attestation_fields()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if tg_op = 'UPDATE' and current_user = 'authenticated' and (
    new.identity_verified is distinct from old.identity_verified
    or new.agreement_signed is distinct from old.agreement_signed
    or new.guarantee_explained is distinct from old.guarantee_explained
    or new.identity_document_type is distinct from old.identity_document_type
    or new.tenant_signature_data is distinct from old.tenant_signature_data
    or new.staff_signature_data is distinct from old.staff_signature_data
    or new.identity_verified_by is distinct from old.identity_verified_by
    or new.identity_verified_at is distinct from old.identity_verified_at
    or new.agreement_signed_by is distinct from old.agreement_signed_by
    or new.agreement_signed_at is distinct from old.agreement_signed_at
    or new.guarantee_explained_by is distinct from old.guarantee_explained_by
    or new.guarantee_explained_at is distinct from old.guarantee_explained_at
  ) then
    raise exception 'Data verifikasi dan tanda tangan hanya dapat dicatat melalui proses transaksi resmi.'
      using errcode = '42501';
  end if;

  if new.identity_verified then
    if new.identity_document_type not in ('KTP','KTM') then
      raise exception 'Jenis identitas wajib KTP atau KTM.' using errcode = '23514';
    end if;
    new.identity_verified_by := coalesce(new.identity_verified_by, auth.uid());
    new.identity_verified_at := coalesce(new.identity_verified_at, now());
    if new.identity_verified_by is null then
      raise exception 'Petugas verifikasi identitas tidak dapat ditentukan.' using errcode = '23514';
    end if;
  end if;

  if new.agreement_signed then
    if new.tenant_signature_data is null
       or new.staff_signature_data is null
       or length(new.tenant_signature_data) > 120000
       or length(new.staff_signature_data) > 120000
       or new.tenant_signature_data not like 'data:image/jpeg;base64,%'
       or new.staff_signature_data not like 'data:image/jpeg;base64,%' then
      raise exception 'Tanda tangan penyewa dan petugas wajib berupa data JPEG yang valid.'
        using errcode = '23514';
    end if;
    new.agreement_signed_by := coalesce(new.agreement_signed_by, auth.uid());
    new.agreement_signed_at := coalesce(new.agreement_signed_at, now());
    if new.agreement_signed_by is null then
      raise exception 'Petugas pencatat perjanjian tidak dapat ditentukan.' using errcode = '23514';
    end if;
  end if;

  if new.guarantee_explained then
    new.guarantee_explained_by := coalesce(new.guarantee_explained_by, auth.uid());
    new.guarantee_explained_at := coalesce(new.guarantee_explained_at, now());
    if new.guarantee_explained_by is null then
      raise exception 'Petugas penjelasan garansi tidak dapat ditentukan.' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists guard_rental_attestation_fields on public.rentals;
create trigger guard_rental_attestation_fields
before insert or update of
  identity_verified, agreement_signed, guarantee_explained,
  identity_document_type, tenant_signature_data, staff_signature_data,
  identity_verified_by, identity_verified_at, agreement_signed_by,
  agreement_signed_at, guarantee_explained_by, guarantee_explained_at
on public.rentals
for each row execute function public.guard_rental_attestation_fields();

create or replace function public.validate_rental_confirmation()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if new.status = 'confirmed' and (
    not new.identity_verified
    or new.identity_document_type not in ('KTP','KTM')
    or new.identity_verified_by is null
    or new.identity_verified_at is null
    or not new.agreement_signed
    or new.tenant_signature_data is null
    or new.staff_signature_data is null
    or new.agreement_signed_by is null
    or new.agreement_signed_at is null
    or not new.guarantee_explained
    or new.guarantee_explained_by is null
    or new.guarantee_explained_at is null
  ) then
    raise exception 'Rental belum dapat dikonfirmasi. Verifikasi identitas, dua tanda tangan, dan penjelasan garansi harus tercatat.'
      using errcode = '23514';
  end if;
  return new;
end;
$function$;

create or replace function public.create_rms_rental(
  p_request_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_unit_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_identity_document_type text,
  p_tenant_signature_data text,
  p_staff_signature_data text,
  p_identity_verified boolean,
  p_agreement_signed boolean,
  p_guarantee_explained boolean,
  p_notes text,
  p_payment_method text default null,
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
    identity_document_type,identity_verified_by,identity_verified_at,
    tenant_signature_data,staff_signature_data,agreement_signed_by,agreement_signed_at,
    guarantee_explained_by,guarantee_explained_at
  ) values(
    v_code,v_customer_id,v_unit.id,p_start_at,p_end_at,v_price,0,
    true,true,true,'reserved',nullif(trim(coalesce(p_notes,'')),''),
    p_identity_document_type,v_user,now(),
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

revoke all on function public.create_rms_rental(uuid,text,text,uuid,timestamptz,timestamptz,text,text,text,boolean,boolean,boolean,text,text,boolean) from public,anon;
grant execute on function public.create_rms_rental(uuid,text,text,uuid,timestamptz,timestamptz,text,text,text,boolean,boolean,boolean,text,text,boolean) to authenticated;
drop function if exists public.create_rms_rental(uuid,text,text,uuid,timestamptz,timestamptz,boolean,boolean,boolean,text,text,boolean);

revoke insert on public.rentals from authenticated;
revoke update on public.rentals from authenticated;
grant update(status,agreement_pdf_path,agreement_pdf_created_at) on public.rentals to authenticated;

alter function public.prevent_rental_schedule_overlap() set search_path = '';
alter function public.validate_rental_unit_eligibility() set search_path = '';

commit;
