-- NgontenYuk.co: audited payment voiding (staging)
-- A voided payment remains in history but is excluded from active rental totals.

begin;

-- Extend the existing payment status check without assuming its generated name.
do $$
declare
  c record;
begin
  for c in
    select conname
    from pg_constraint
    where conrelid = 'public.payments'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%payment_status%'
  loop
    execute format('alter table public.payments drop constraint %I', c.conname);
  end loop;
end;
$$;

alter table public.payments
  add constraint payments_payment_status_check
  check (payment_status in ('pending','paid','failed','refunded','voided'));

-- Allow owner/admin voiding from pending or paid. Other transitions remain unchanged.
create or replace function public.validate_payment_status_transition()
returns trigger
language plpgsql
as $function$
begin
  if new.payment_status = old.payment_status then
    return new;
  end if;

  if not (
    (old.payment_status = 'pending' and new.payment_status in ('paid','failed','voided'))
    or (old.payment_status = 'failed' and new.payment_status = 'pending')
    or (old.payment_status = 'paid' and new.payment_status in ('refunded','voided'))
  ) then
    raise exception
      'Perubahan status pembayaran tidak diizinkan: % menjadi %.',
      old.payment_status, new.payment_status
      using errcode = '23514';
  end if;

  return new;
end;
$function$;

create table if not exists public.payment_void_audit (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete restrict,
  rental_id uuid not null references public.rentals(id) on delete restrict,
  amount numeric not null check (amount > 0),
  previous_status text not null check (previous_status in ('pending','paid')),
  reason text not null check (char_length(trim(reason)) >= 5),
  voided_by uuid not null references auth.users(id) on delete restrict,
  voided_at timestamptz not null default now()
);

create index if not exists payment_void_audit_payment_idx
  on public.payment_void_audit(payment_id, voided_at desc);

alter table public.payment_void_audit enable row level security;

drop policy if exists "Owner admin read payment void audit" on public.payment_void_audit;
create policy "Owner admin read payment void audit"
  on public.payment_void_audit
  for select to authenticated
  using (public.current_user_role() in ('owner','admin'));

revoke all on public.payment_void_audit from anon, authenticated;
grant select on public.payment_void_audit to authenticated;

create or replace function public.void_payment(
  p_payment_id uuid,
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
  v_reason text := trim(coalesce(p_reason,''));
begin
  if auth.uid() is null then
    raise exception 'Sesi login diperlukan.';
  end if;

  if coalesce(public.current_user_role(),'') not in ('owner','admin') then
    raise exception 'Hanya Owner/Admin yang dapat membatalkan pembayaran.';
  end if;

  if char_length(v_reason) < 5 then
    raise exception 'Alasan pembatalan minimal 5 karakter.';
  end if;

  select * into v_payment
  from public.payments
  where id = p_payment_id;

  if not found then
    raise exception 'Transaksi pembayaran tidak ditemukan.';
  end if;

  if v_payment.payment_type <> 'rental'
     or v_payment.payment_status not in ('pending','paid') then
    raise exception 'Hanya pembayaran rental pending atau paid yang dapat dibatalkan.';
  end if;

  -- Lock the rental and payment rows to serialize operations for this rental.
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
    raise exception 'Status pembayaran sudah berubah. Muat ulang halaman.';
  end if;

  update public.payments
  set payment_status = 'voided'
  where id = p_payment_id;

  insert into public.payment_void_audit
    (payment_id, rental_id, amount, previous_status, reason, voided_by)
  values
    (p_payment_id, v_payment.rental_id, v_payment.amount,
     v_payment.payment_status, v_reason, auth.uid());

  return jsonb_build_object(
    'payment_id', p_payment_id,
    'amount', v_payment.amount,
    'previous_status', v_payment.payment_status,
    'payment_status', 'voided'
  );
end;
$$;

revoke all on function public.void_payment(uuid,text) from public, anon;
grant execute on function public.void_payment(uuid,text) to authenticated;

commit;
