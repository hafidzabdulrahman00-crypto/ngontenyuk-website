begin;
create or replace function public.submit_public_review(p_customer_name text,p_rating integer,p_comment text)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
 v_name text := nullif(trim(coalesce(p_customer_name,'')),'');
 v_comment text := nullif(trim(coalesce(p_comment,'')),'');
 v_id uuid;
begin
 if v_name is null or char_length(v_name)<2 or char_length(v_name)>40 then raise exception 'Nama harus terdiri dari 2 sampai 40 karakter.'; end if;
 if p_rating is null or p_rating<1 or p_rating>5 then raise exception 'Rating harus antara 1 sampai 5.'; end if;
 if v_comment is null or char_length(v_comment)<5 or char_length(v_comment)>400 then raise exception 'Komentar harus terdiri dari 5 sampai 400 karakter.'; end if;
 if exists(select 1 from public.reviews r where lower(r.customer_name)=lower(v_name) and r.created_at>now()-interval '60 seconds') then
  raise exception 'Tunggu sebentar sebelum mengirim review berikutnya.';
 end if;
 insert into public.reviews(customer_name,rating,comment,is_published) values(v_name,p_rating,v_comment,false) returning id into v_id;
 return jsonb_build_object('id',v_id,'status','pending_moderation');
end;
$function$;
revoke all on function public.submit_public_review(text,integer,text) from public;
grant execute on function public.submit_public_review(text,integer,text) to anon, authenticated;
commit;