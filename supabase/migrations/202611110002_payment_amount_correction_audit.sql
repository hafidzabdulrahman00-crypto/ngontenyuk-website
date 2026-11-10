-- NgontenYuk.co: audited payment amount correction
-- Apply in Supabase SQL Editor on the staging project before using the RMS correction form.

create table if not exists public.payment_correction_audit (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete restrict,
  rental_id uuid not null references public.rentals(id) on delete restrict,
  old_amount numeric not null check (old_amount > 0),
  new_amount numeric not null check (new_amount > 0),
  reason text not null check (char_length(trim(reason)) >= 5),
  changed_by uuid not null references auth.users(id) on delete restrict,
  changed_at timestamptz not null default now()
);

create index if not exists payment_correction_audit_payment_idx
  on public.payment_correction_audit(payment_id, changed_at desc);

alter table public.payment_correction_audit enable row level security;

drop policy if exists "Owner admin read payment correction audit" on public.payment_correction_audit;
create policy "Owner admin read payment correction audit"
  on public.payment_correction_audit
  for select
  to authenticated
  using (public.current_user_role() in ('owner','admin'));

revoke all on public.payment_correction_audit from anon, authenticated;
grant select on public.payment_correction_audit to authenticated;

create or replace function public.correct_payment_amount(
  p_payment_id uuid,
  p_new_amount numeric,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.payments%rowtype;
  v_rental public.rentals%rowtype;
  v_other_active numeric := 0;
  v_old_amount numeric;
  v_reason text := trim(coalesce(p_reason, ''));
begin
  if auth.uid() is null then
    raise exception 'Sesi login diperlukan.';
  end if;

  if coalesce(public.current_user_role(), '') not in ('owner','admin') then
    raise exception 'Hanya Owner/Admin yang dapat mengoreksi pembayaran.';
  end if;

  if p_new_amount is null or p_new_amount <= 0 then
    raise exception 'Nominal baru harus lebih dari nol.';
  end if;

  if v_reason is null or char_length(v_reason) < 5 then
    raise exception 'Alasan koreksi minimal 5 karakter.';
  end if;

  select * into v_payment
  from public.payments
  where id = p_payment_id;

  if not found then
    raise exception 'Transaksi pembayaran tidak ditemukan.';
  end if;

  if v_payment.payment_type <> 'rental'
     or v_payment.payment_status not in ('pending','paid') then
    raise exception 'Hanya pembayaran rental berstatus pending atau paid yang dapat dikoreksi.';
  end if;

  -- Serialize corrections for the same rental to prevent concurrent overpayment.
  select * into v_rental
  from public.rentals
  where id = v_payment.rental_id
  for update;

  if not found then
    raise exception 'Data rental tidak ditemukan.';
  end if;

  select * into v_payment
  from public.payments
  where id = p_payment_id
  for update;

  if v_payment.payment_status not in ('pending','paid') then
    raise exception 'Status pembayaran berubah. Muat ulang halaman.';
  end if;

  v_old_amount := v_payment.amount;

  select coalesce(sum(amount),0) into v_other_active
  from public.payments
  where rental_id = v_payment.rental_id
    and payment_type = 'rental'
    and payment_status in ('pending','paid')
    and id <> p_payment_id;

  if p_new_amount + v_other_active > v_rental.rental_price then
    raise exception 'Nominal baru melebihi sisa batas tagihan rental. Pembayaran aktif lainnya: %, harga rental: %.',
      v_other_active, v_rental.rental_price;
  end if;

  update public.payments
  set amount = p_new_amount
  where id = p_payment_id;

  insert into public.payment_correction_audit
    (payment_id, rental_id, old_amount, new_amount, reason, changed_by)
  values
    (p_payment_id, v_payment.rental_id, v_old_amount, p_new_amount, v_reason, auth.uid());

  return jsonb_build_object(
    'payment_id', p_payment_id,
    'old_amount', v_old_amount,
    'new_amount', p_new_amount,
    'payment_status', v_payment.payment_status
  );
end;
$$;

revoke all on function public.correct_payment_amount(uuid,numeric,text) from public, anon;
grant execute on function public.correct_payment_amount(uuid,numeric,text) to authenticated;
