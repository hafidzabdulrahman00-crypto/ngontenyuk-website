create or replace function public.validate_rental_confirmation()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if new.status = 'confirmed' then
    if not new.identity_verified or not new.agreement_signed or not new.guarantee_explained then
      raise exception 'Penyewaan belum dapat dikonfirmasi. Lengkapi ketiga persyaratan terlebih dahulu.'
        using errcode = '23514';
    end if;
    -- Do not fabricate staff attribution for pre-existing rentals.
    if new.created_at >= timestamptz '2026-11-12 03:36:18+00' and (
      new.identity_document_type not in ('KTP','KTM')
      or new.identity_verified_by is null or new.identity_verified_at is null
      or new.tenant_signature_data is null or new.staff_signature_data is null
      or new.agreement_signed_by is null or new.agreement_signed_at is null
      or new.guarantee_explained_by is null or new.guarantee_explained_at is null
    ) then
      raise exception 'Rental baru belum memiliki bukti verifikasi, tanda tangan, dan penjelasan garansi yang lengkap.'
        using errcode = '23514';
    end if;
  end if;
  return new;
end;
$function$;
