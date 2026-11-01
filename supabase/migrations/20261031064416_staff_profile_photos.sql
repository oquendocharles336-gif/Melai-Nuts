-- =============================================================================
-- Melai Nuts — Migration 20261031064416: staff profile photos
-- =============================================================================
-- Run after 20261031052943_loyalty_points_on_completion_only.sql. Idempotent.
--
-- Staff can put a picture on their profile.
--
--  * Bucket staff-photos: private, images only, at most 2 MB. A file lives in a
--    folder named after its owner's account, and only that person may add or
--    remove it. Active staff may read them, through short-lived signed links.
--  * staff_set_my_photo stores the path on the caller's own staff row. Staff have
--    no UPDATE right on staff_members, so this is the only way to change it, and it
--    only accepts a file from the caller's own folder.
-- =============================================================================
begin;

do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('staff-photos', 'staff-photos', false, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
    on conflict (id) do update
      set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

    execute $p$drop policy if exists "staff add own photo" on storage.objects$p$;
    execute $p$create policy "staff add own photo" on storage.objects for insert to authenticated
      with check (bucket_id = 'staff-photos'
        and split_part(name, '/', 1) = public.current_firebase_uid()
        and exists (select 1 from public.staff_members s
                    where s.firebase_uid = public.current_firebase_uid() and s.account_status = 'active'))$p$;

    execute $p$drop policy if exists "staff remove own photo" on storage.objects$p$;
    execute $p$create policy "staff remove own photo" on storage.objects for delete to authenticated
      using (bucket_id = 'staff-photos' and split_part(name, '/', 1) = public.current_firebase_uid())$p$;

    execute $p$drop policy if exists "staff read photos" on storage.objects$p$;
    execute $p$create policy "staff read photos" on storage.objects for select to authenticated
      using (bucket_id = 'staff-photos'
        and exists (select 1 from public.staff_members s
                    where s.firebase_uid = public.current_firebase_uid() and s.account_status = 'active'))$p$;
  end if;
end
$do$;

create or replace function public.staff_set_my_photo(p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.staff_members;
  v_path text := nullif(trim(coalesce(p_path, '')), '');
begin
  v_staff := public._require_staff();
  if v_path is not null
     and (split_part(v_path, '/', 1) is distinct from v_staff.firebase_uid
          or v_path like '%..%'
          or char_length(v_path) > 300) then
    raise exception 'That photo does not belong to your account.';
  end if;
  update public.staff_members set profile_image = v_path where firebase_uid = v_staff.firebase_uid;
end;
$$;
revoke all on function public.staff_set_my_photo(text) from public, anon;
grant execute on function public.staff_set_my_photo(text) to authenticated;

commit;
