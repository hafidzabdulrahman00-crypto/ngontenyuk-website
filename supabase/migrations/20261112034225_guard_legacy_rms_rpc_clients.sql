-- Reject legacy RMS clients that cannot submit signatures atomically.
-- This keeps old deployments from creating rentals without signature evidence.

create or replace function public.create_rms_rental(
  p_request_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_unit_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_identity_verified boolean,
  p_agreement_signed boolean,
  p_guarantee_explained boolean,
  p_notes text,
  p_payment_method text default null,
  p_cash_received boolean default false
)
returns jsonb
language plpgsql
security invoker
set search_path to ''
as $function$
begin
  raise exception 'Aplikasi Staff RMS perlu diperbarui sebelum membuat rental. Muat ulang halaman dan coba kembali.';
end;
$function$;

revoke all on function public.create_rms_rental(uuid,text,text,uuid,timestamptz,timestamptz,boolean,boolean,boolean,text,text,boolean) from public, anon;
grant execute on function public.create_rms_rental(uuid,text,text,uuid,timestamptz,timestamptz,boolean,boolean,boolean,text,text,boolean) to authenticated;
