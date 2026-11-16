begin;
create table if not exists public.rental_returns (
 id uuid primary key default gen_random_uuid(),
 rental_id uuid not null unique references public.rentals(id) on delete restrict,
 unit_id uuid not null references public.units(id) on delete restrict,
 returned_by uuid not null references public.profiles(id) on delete restrict,
 return_condition text not null check(return_condition in ('new','good','fair','damaged')),
 notes text,
 returned_at timestamptz not null default now()
);
alter table public.rental_returns enable row level security;
drop policy if exists "Staff read rental returns" on public.rental_returns;
create policy "Staff read rental returns" on public.rental_returns for select to authenticated
using ((select public.current_user_role()) in ('owner','admin','staff'));
grant select on public.rental_returns to authenticated;
create or replace function public.complete_rental_return(p_rental_id uuid,p_return_condition text,p_notes text default null)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
 v_rental public.rentals%rowtype;
 v_unit public.units%rowtype;
 v_role text;
 v_notes text := nullif(trim(coalesce(p_notes,'')),'');
 v_new_status text;
begin
 if auth.uid() is null then raise exception 'Sesi login diperlukan.'; end if;
 v_role:=coalesce(public.current_user_role(),'');
 if v_role not in ('owner','admin','staff') then raise exception 'Akses pengembalian ditolak.'; end if;
 if p_return_condition not in ('new','good','fair','damaged') then raise exception 'Kondisi pengembalian tidak valid.'; end if;
 if v_notes is not null and char_length(v_notes)>500 then raise exception 'Catatan pengembalian maksimal 500 karakter.'; end if;
 select * into v_rental from public.rentals where id=p_rental_id for update;
 if not found then raise exception 'Rental tidak ditemukan.'; end if;
 if v_rental.status<>'ongoing' then raise exception 'Pengembalian hanya dapat dicatat untuk rental yang sedang berlangsung.'; end if;
 select * into v_unit from public.units where id=v_rental.unit_id for update;
 if not found then raise exception 'Unit rental tidak ditemukan.'; end if;
 v_new_status:=case when p_return_condition='damaged' then 'maintenance' else 'available' end;
 update public.rentals set status='completed' where id=p_rental_id;
 update public.units set condition=p_return_condition,operational_status=v_new_status where id=v_unit.id;
 insert into public.rental_returns(rental_id,unit_id,returned_by,return_condition,notes)
 values(p_rental_id,v_unit.id,auth.uid(),p_return_condition,v_notes);
 return jsonb_build_object('rental_id',p_rental_id,'rental_status','completed','unit_id',v_unit.id,'unit_code',v_unit.unit_code,'condition',p_return_condition,'operational_status',v_new_status,'returned_at',now());
end;
$function$;
revoke all on function public.complete_rental_return(uuid,text,text) from public,anon;
grant execute on function public.complete_rental_return(uuid,text,text) to authenticated;
commit;