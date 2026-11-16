-- Harden remaining trigger and payment RPC search paths.
alter function public.manage_payment_timestamp() set search_path = '';
alter function public.validate_payment_status_transition() set search_path = '';
alter function public.prevent_rental_price_change_after_payment() set search_path = '';
alter function public.validate_rental_status_transition() set search_path = '';
alter function public.correct_payment_amount(uuid,numeric,text) set search_path = '';
alter function public.void_payment(uuid,text) set search_path = '';
alter function public.apply_midtrans_qris_notification(text,text,numeric,text,jsonb) set search_path = '';
