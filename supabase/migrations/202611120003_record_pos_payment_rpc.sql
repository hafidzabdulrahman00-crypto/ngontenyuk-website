-- NgontenYuk.co: secure POS payment recording RPC.
-- POS inserts the rental first, then calls this function once per rental.
-- The function records a pending payment first (required by the payment trigger),
-- and marks cash paid only after the cashier explicitly confirms receipt.
-- No existing rental/payment rows are modified by applying this migration.

begin;

create or replace function public.record_pos_payment(
  p_rental_id uuid,
  p_amount numeric,
  p_payment_method text,
  p_cash_received boolean default false
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_role text;
  v_rental public.rentals%rowtype;
  v_payment_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Sesi login diperlukan.';
  end if;

  v_role := coalesce(public.current_user_role(), '');
  if v_role not in ('owner', 'admin', 'staff') then
    raise exception 'Akses POS ditolak.';
  end if;

  if p_rental_id is null then
    raise exception 'Rental wajib dipilih.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Nominal pembayaran harus lebih dari nol.';
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

  -- Serialize payments against the rental's price and status.
  select *
    into v_rental
  from public.rentals
  where id = p_rental_id
  for update;

  if not found then
    raise exception 'Rental tidak ditemukan.';
  end if;

  if v_rental.status not in ('reserved', 'confirmed', 'ongoing') then
    raise exception 'Pembayaran tidak dapat dicatat untuk rental dengan status %.', v_rental.status;
  end if;

  if p_amount > v_rental.rental_price then
    raise exception 'Nominal pembayaran melebihi harga rental.';
  end if;

  insert into public.payments (
    rental_id,
    amount,
    payment_type,
    payment_method,
    payment_status
  )
  values (
    p_rental_id,
    p_amount,
    'rental',
    p_payment_method,
    'pending'
  )
  returning id into v_payment_id;

  if p_payment_method = 'cash' then
    update public.payments
    set payment_status = 'paid',
        paid_at = now()
    where id = v_payment_id;
  end if;

  return v_payment_id;
end;
$function$;

revoke all on function public.record_pos_payment(uuid, numeric, text, boolean)
  from public, anon;
grant execute on function public.record_pos_payment(uuid, numeric, text, boolean)
  to authenticated;

commit;
