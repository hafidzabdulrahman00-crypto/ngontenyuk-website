begin;

-- Lokasi penyimpanan PDF perjanjian.
alter table public.rentals
  add column if not exists agreement_pdf_path text,
  add column if not exists agreement_pdf_created_at timestamptz;

comment on column public.rentals.agreement_pdf_path
  is 'Private Supabase Storage object path for the rental agreement PDF';

comment on column public.rentals.agreement_pdf_created_at
  is 'Timestamp when the rental agreement PDF was uploaded';

-- Bucket privat khusus PDF perjanjian.
insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'rental-agreements',
  'rental-agreements',
  false,
  10485760,
  array['application/pdf']
)
on conflict (id) do update
set
  public = false,
  file_size_limit = 10485760,
  allowed_mime_types = array['application/pdf'];

-- Akses hanya untuk Staff, Admin, dan Owner.

drop policy if exists rental_agreements_staff_select
  on storage.objects;

create policy rental_agreements_staff_select
on storage.objects
for select
to authenticated
using (
  bucket_id = 'rental-agreements'
  and (select public.current_user_role()) in ('owner', 'admin', 'staff')
  and exists (
    select 1
    from public.rentals r
    where r.id::text = (storage.foldername(name))[1]
  )
);

drop policy if exists rental_agreements_staff_insert
  on storage.objects;

create policy rental_agreements_staff_insert
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'rental-agreements'
  and (select public.current_user_role()) in ('owner', 'admin', 'staff')
  and exists (
    select 1
    from public.rentals r
    where r.id::text = (storage.foldername(name))[1]
  )
);

drop policy if exists rental_agreements_staff_update
  on storage.objects;

create policy rental_agreements_staff_update
on storage.objects
for update
to authenticated
using (
  bucket_id = 'rental-agreements'
  and (select public.current_user_role()) in ('owner', 'admin', 'staff')
  and exists (
    select 1
    from public.rentals r
    where r.id::text = (storage.foldername(name))[1]
  )
)
with check (
  bucket_id = 'rental-agreements'
  and (select public.current_user_role()) in ('owner', 'admin', 'staff')
  and exists (
    select 1
    from public.rentals r
    where r.id::text = (storage.foldername(name))[1]
  )
);

drop policy if exists rental_agreements_staff_delete
  on storage.objects;

create policy rental_agreements_staff_delete
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'rental-agreements'
  and (select public.current_user_role()) in ('owner', 'admin')
);

commit;

notify pgrst, 'reload schema';
