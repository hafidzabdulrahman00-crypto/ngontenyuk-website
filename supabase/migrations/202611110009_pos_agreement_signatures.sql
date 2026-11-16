begin;

alter table public.rentals
  add column if not exists identity_document_type text,
  add column if not exists identity_deposit_status text not null default 'not_received',
  add column if not exists identity_received_at timestamptz,
  add column if not exists identity_returned_at timestamptz,
  add column if not exists tenant_signature_data text,
  add column if not exists staff_signature_data text,
  add column if not exists agreement_signed_at timestamptz,
  add column if not exists agreement_version text not null default 'NY-RENTAL-2026-01';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'rentals_identity_document_type_check') then
    alter table public.rentals add constraint rentals_identity_document_type_check
      check (identity_document_type is null or identity_document_type in ('KTP','KTM'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'rentals_identity_deposit_status_check') then
    alter table public.rentals add constraint rentals_identity_deposit_status_check
      check (identity_deposit_status in ('not_received','held','returned'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'rentals_signature_size_check') then
    alter table public.rentals add constraint rentals_signature_size_check
      check (
        (tenant_signature_data is null or length(tenant_signature_data) <= 120000)
        and (staff_signature_data is null or length(staff_signature_data) <= 120000)
      );
  end if;
end $$;

comment on column public.rentals.identity_document_type is 'Jenis dokumen jaminan fisik; nomor/foto dokumen tidak disimpan.';
comment on column public.rentals.identity_deposit_status is 'Status penitipan dokumen jaminan fisik.';
comment on column public.rentals.tenant_signature_data is 'Data tanda tangan elektronik sederhana penyewa (data URL PNG), bukan sertifikat tanda tangan tersertifikasi.';
comment on column public.rentals.staff_signature_data is 'Data tanda tangan elektronik sederhana petugas (data URL PNG), bukan sertifikat tanda tangan tersertifikasi.';

commit;