-- =============================================================================
-- Melai Nuts — Migration 20261102000000: Product images storage bucket and RLS
-- =============================================================================
-- Creates the public 'product-images' storage bucket (jpeg/png/webp, max 2 MB)
-- and security policies allowing anyone to read product images, but only
-- owner/admin accounts to insert, update and delete.
-- =============================================================================
begin;

do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('product-images', 'product-images', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
    on conflict (id) do update
      set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

    execute $p$drop policy if exists "anyone reads product images" on storage.objects$p$;
    execute $p$create policy "anyone reads product images" on storage.objects for select
      using (bucket_id = 'product-images')$p$;

    execute $p$drop policy if exists "owners manage product images" on storage.objects$p$;
    execute $p$create policy "owners manage product images" on storage.objects for all to authenticated
      using (
        bucket_id = 'product-images'
        and exists (
          select 1 from public.staff_members s
          where s.firebase_uid = public.current_firebase_uid()
            and s.account_status = 'active'
            and s.role = 'owner'
        )
      )
      with check (
        bucket_id = 'product-images'
        and exists (
          select 1 from public.staff_members s
          where s.firebase_uid = public.current_firebase_uid()
            and s.account_status = 'active'
            and s.role = 'owner'
        )
      )$p$;
  end if;
end
$do$;

commit;
