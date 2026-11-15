-- Módulo del guarda (8): foto del DPI o licencia del visitante (decisión de Isaac, 2026-11-15:
-- "quiero tener las fotos del DPI desde mi panel y poder borrarlas, corro el riesgo").
-- * Bucket privado "visitor_docs". Ruta: <empresa>/<sitio>/<id del ingreso>.jpg
-- * La SUBE el guarda asignado al sitio (con control de visitas). Después no la puede volver a ver.
-- * La VEN y la BORRAN solo el administrador de la empresa y el súper admin. El supervisor no.
-- * Cada borrado queda en la bitácora (cuántas y quién). Requisito: aviso visible en la garita.

alter table public.access_entries
  add column if not exists doc_photo_path text,
  add column if not exists doc_photo_at timestamptz;
create index if not exists access_entries_photo_idx on public.access_entries (company_id, entered_at)
  where doc_photo_path is not null;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('visitor_docs', 'visitor_docs', false, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- Subir: guarda activo del sitio, en la carpeta de su empresa y su sitio, sitio con control de visitas.
create or replace function private.can_upload_visitor_doc(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select private.user_role() = 'guard'
       and s.visitor_control and s.active
       and s.company_id = private.try_uuid((storage.foldername(p_name))[1])
       and exists (select 1 from public.guard_sites gs
                   where gs.site_id = s.id and gs.guard_id = (select auth.uid()) and gs.active)
    from public.sites s
    where s.id = private.try_uuid((storage.foldername(p_name))[2])), false)
$$;

-- Ver y borrar: administrador de la empresa (is_admin_of incluye al súper admin).
create or replace function private.can_manage_visitor_doc(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_admin_of(private.try_uuid((storage.foldername(p_name))[1]))
$$;

create policy "visitor_docs: subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'visitor_docs' and private.can_upload_visitor_doc(name));
create policy "visitor_docs: ver" on storage.objects for select to authenticated
  using (bucket_id = 'visitor_docs' and private.can_manage_visitor_doc(name));
create policy "visitor_docs: borrar" on storage.objects for delete to authenticated
  using (bucket_id = 'visitor_docs' and private.can_manage_visitor_doc(name));

-- El guarda que registró el ingreso anota dónde quedó la foto (después de subirla).
create or replace function public.set_entry_photo(p_entry_id uuid, p_path text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v public.access_entries%rowtype;
begin
  select * into v from public.access_entries where id = p_entry_id for update;
  if not found then
    raise exception 'ingreso no encontrado' using errcode = '22023';
  end if;
  if v.entered_by is distinct from (select auth.uid()) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  if p_path is distinct from (v.company_id::text || '/' || v.site_id::text || '/' || v.id::text || '.jpg') then
    raise exception 'ruta de foto inválida' using errcode = '22023';
  end if;
  update public.access_entries set doc_photo_path = p_path, doc_photo_at = now() where id = p_entry_id;
end $$;

-- El administrador quita la referencia a las fotos que ya borró del almacenamiento.
create or replace function public.clear_entry_photos(p_ids uuid[])
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_company uuid;
  v_n integer;
begin
  if p_ids is null or cardinality(p_ids) = 0 then
    return 0;
  end if;
  select distinct e.company_id into v_company from public.access_entries e where e.id = any (p_ids) limit 1;
  if v_company is null then
    return 0;
  end if;
  if exists (select 1 from public.access_entries e where e.id = any (p_ids) and e.company_id <> v_company)
     or not private.is_admin_of(v_company) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  update public.access_entries set doc_photo_path = null, doc_photo_at = null
   where id = any (p_ids) and doc_photo_path is not null;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into public.audit_log (company_id, actor, action, detail)
    values (v_company, (select auth.uid()), 'visitor_photos_deleted', v_n::text || ' fotos de documento');
  end if;
  return v_n;
end $$;

revoke execute on function public.set_entry_photo(uuid, text) from public, anon;
revoke execute on function public.clear_entry_photos(uuid[]) from public, anon;
grant execute on function public.set_entry_photo(uuid, text) to authenticated;
grant execute on function public.clear_entry_photos(uuid[]) to authenticated;
