-- Módulo 2 · Almacenamiento privado de fotos de perfil, logos y escaneos de documentos.

-- ---------------------------------------------------------------------------
-- Almacenamiento privado (se descarga con URL firmada).
--   avatars:   {profile_id}/{archivo}                 foto de perfil
--   logos:     {company_id}/{archivo}                 logo de la empresa
--   documents: {company_id}/{document_id}/{archivo}   escaneo del documento (crear la fila primero)
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('avatars',   'avatars',   false, 2097152,  array['image/jpeg', 'image/png', 'image/webp']),
  ('logos',     'logos',     false, 1048576,  array['image/jpeg', 'image/png', 'image/webp']),
  ('documents', 'documents', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create or replace function private.storage_doc_access(p_name text, p_write boolean) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select case when p_write then private.doc_editable(d.profile_id, d.company_id)
                else private.doc_visible(d.profile_id, d.client_id, d.company_id) end
    from public.documents d
    where d.id = private.try_uuid((storage.foldername(p_name))[2])
      and d.company_id = private.try_uuid((storage.foldername(p_name))[1])), false)
$$;

create policy "avatars: ver" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and private.can_view_person(private.try_uuid((storage.foldername(name))[1])));
create policy "avatars: subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and private.can_edit_person(private.try_uuid((storage.foldername(name))[1])));
create policy "avatars: cambiar" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and private.can_edit_person(private.try_uuid((storage.foldername(name))[1])))
  with check (bucket_id = 'avatars' and private.can_edit_person(private.try_uuid((storage.foldername(name))[1])));
create policy "avatars: borrar" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and private.can_edit_person(private.try_uuid((storage.foldername(name))[1])));

create policy "logos: ver" on storage.objects for select to authenticated
  using (bucket_id = 'logos' and (private.user_role() = 'super_admin'
         or private.try_uuid((storage.foldername(name))[1]) = private.user_company()));
create policy "logos: subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'logos' and private.is_admin_of(private.try_uuid((storage.foldername(name))[1])));
create policy "logos: cambiar" on storage.objects for update to authenticated
  using (bucket_id = 'logos' and private.is_admin_of(private.try_uuid((storage.foldername(name))[1])))
  with check (bucket_id = 'logos' and private.is_admin_of(private.try_uuid((storage.foldername(name))[1])));
create policy "logos: borrar" on storage.objects for delete to authenticated
  using (bucket_id = 'logos' and private.is_admin_of(private.try_uuid((storage.foldername(name))[1])));

create policy "documents: ver" on storage.objects for select to authenticated
  using (bucket_id = 'documents' and private.storage_doc_access(name, false));
create policy "documents: subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and private.storage_doc_access(name, true));
create policy "documents: cambiar" on storage.objects for update to authenticated
  using (bucket_id = 'documents' and private.storage_doc_access(name, true))
  with check (bucket_id = 'documents' and private.storage_doc_access(name, true));
create policy "documents: borrar" on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and private.storage_doc_access(name, true));
