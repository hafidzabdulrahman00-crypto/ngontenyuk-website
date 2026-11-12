-- Prevent stale Midtrans notifications from downgrading gateway transaction state.
begin;

create or replace function public.apply_midtrans_qris_notification(
  p_order_id text,
  p_transaction_id text,
  p_amount numeric,
  p_gateway_status text,
  p_notification jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_tx public.payment_gateway_transactions%rowtype;
  v_total numeric(14,2);
  v_count integer;
  v_paid integer;
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception 'Akses hanya untuk service role.';
  end if;

  if p_gateway_status not in ('pending','settlement','expire','deny','cancel','failure') then
    raise exception 'Status gateway tidak dikenal.';
  end if;

  select * into v_tx
  from public.payment_gateway_transactions
  where order_id = p_order_id
  for update;

  if not found then
    raise exception 'Order gateway tidak ditemukan.';
  end if;

  if round(v_tx.amount,2) <> round(p_amount,2) then
    raise exception 'Nominal notifikasi tidak sesuai dengan transaksi.';
  end if;

  -- Ignore stale or duplicate non-settlement notifications after a terminal state.
  -- A verified settlement may supersede a prior non-settlement state, but never
  -- allow a later pending/failed notification to downgrade a settled transaction.
  if v_tx.status = 'settlement' and p_gateway_status <> 'settlement' then
    return jsonb_build_object(
      'order_id',p_order_id,
      'gateway_status',v_tx.status,
      'ignored_stale_notification',true,
      'payments_paid',cardinality(v_tx.payment_ids)
    );
  end if;

  if v_tx.status in ('expire','deny','cancel','failure')
     and p_gateway_status in ('pending','expire','deny','cancel','failure')
     and p_gateway_status <> v_tx.status then
    return jsonb_build_object(
      'order_id',p_order_id,
      'gateway_status',v_tx.status,
      'ignored_stale_notification',true,
      'payments_paid',0
    );
  end if;

  select count(*), coalesce(sum(amount),0)
    into v_count, v_total
  from public.payments
  where id = any(v_tx.payment_ids)
    and payment_status in ('pending','paid');

  if v_count <> cardinality(v_tx.payment_ids)
     or round(v_total,2) <> round(v_tx.amount,2) then
    raise exception 'Rincian pembayaran POS tidak cocok dengan total QRIS.';
  end if;

  if p_gateway_status = 'settlement' then
    if coalesce(p_notification->>'status_code','') <> '200'
       or coalesce(lower(p_notification->>'payment_type'),'') <> 'qris'
       or coalesce(lower(p_notification->>'fraud_status'),'accept') <> 'accept' then
      raise exception 'Notifikasi settlement belum memenuhi validasi pembayaran.';
    end if;
  end if;

  update public.payment_gateway_transactions
  set status = p_gateway_status,
      transaction_id = coalesce(p_transaction_id, transaction_id),
      notification = p_notification,
      settled_at = case when p_gateway_status = 'settlement' then coalesce(settled_at,now()) else settled_at end
  where id = v_tx.id;

  if p_gateway_status = 'settlement' then
    update public.payments
    set payment_status = 'paid',
        paid_at = coalesce(paid_at, now())
    where id = any(v_tx.payment_ids)
      and payment_status = 'pending';

    select count(*) into v_paid
    from public.payments
    where id = any(v_tx.payment_ids)
      and payment_status = 'paid';

    if v_paid <> cardinality(v_tx.payment_ids) then
      raise exception 'Tidak semua pembayaran rental berhasil diperbarui.';
    end if;
  end if;

  return jsonb_build_object(
    'order_id',p_order_id,
    'gateway_status',p_gateway_status,
    'ignored_stale_notification',false,
    'payments_paid',case when p_gateway_status='settlement' then cardinality(v_tx.payment_ids) else 0 end
  );
end;
$function$;

revoke all on function public.apply_midtrans_qris_notification(text,text,numeric,text,jsonb) from public, anon, authenticated;
grant execute on function public.apply_midtrans_qris_notification(text,text,numeric,text,jsonb) to service_role;

commit;
