-- Historial de visitas: un solo buscador por placa, DPI, nombre o empresa (de dónde viene o a dónde va).
-- Corre con los permisos de quien busca (RLS de access_entries): el admin ve su empresa, el súper admin
-- todas, el supervisor solo sus sitios y el guarda nada.

-- Minúsculas y sin tildes, para que "perez" encuentre "Pérez".
create or replace function private.fold(p text) returns text
language sql immutable set search_path = '' as $$
  select lower(translate(coalesce(p, ''),
    'ÁÀÄÂÉÈËÊÍÌÏÎÓÒÖÔÚÙÜÛÑáàäâéèëêíìïîóòöôúùüûñ',
    'AAAAEEEEIIIIOOOOUUUUNaaaaeeeeiiiioooouuuun'))
$$;

create index if not exists access_entries_company_idx on public.access_entries (company_id, entered_at desc);
create index if not exists access_entries_doc_idx on public.access_entries (company_id, doc_number) where doc_number is not null;

create or replace function public.search_visits(
  p_q text default null,
  p_company uuid default null,
  p_site uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit integer default 200)
returns table (
  id uuid, site_id uuid, site_name text, kind text, plate text, person_name text, doc_kind text, doc_number text,
  company_name text, destination text, status text, entered_at timestamptz, exited_at timestamptz,
  entered_by_name text, exited_by_name text, entry_offline boolean, exit_offline boolean, doc_photo_path text,
  total_visits bigint, total_people bigint, total_vehicles bigint, first_at timestamptz, last_at timestamptz)
language sql stable security invoker set search_path = '' as $$
  with t as (
    select nullif(btrim(coalesce(p_q, '')), '') as raw,
           upper(regexp_replace(coalesce(p_q, ''), '[^A-Za-z0-9]', '', 'g')) as alnum,
           regexp_replace(coalesce(p_q, ''), '[^0-9]', '', 'g') as digits,
           array_remove(string_to_array(regexp_replace(private.fold(p_q), '\s+', ' ', 'g'), ' '), '') as words
  ), m as (
    select e.id, e.site_id, s.name as site_name, e.kind, e.plate, e.person_name, e.doc_kind, e.doc_number,
           coalesce(vc.name, e.visitor_company_text) as company_name, e.destination, e.status,
           e.entered_at, e.exited_at, e.entered_by, e.exited_by, e.entry_offline, e.exit_offline, e.doc_photo_path
    from public.access_entries e
    join public.sites s on s.id = e.site_id
    left join public.visitor_companies vc on vc.id = e.visitor_company_id
    cross join t
    where (p_company is null or e.company_id = p_company)
      and (p_site is null or e.site_id = p_site)
      and (p_from is null or e.entered_at >= p_from)
      and (p_to is null or e.entered_at < p_to)
      and (t.raw is null
           or (length(t.alnum) >= 3 and e.plate like '%' || t.alnum || '%')
           or (length(t.digits) >= 4 and e.doc_number like '%' || t.digits || '%')
           or (cardinality(t.words) > 0 and (
                 not exists (select 1 from unnest(t.words) w where private.fold(e.person_name) not like '%' || w || '%')
              or not exists (select 1 from unnest(t.words) w
                             where private.fold(coalesce(vc.name, e.visitor_company_text)) not like '%' || w || '%')
              or not exists (select 1 from unnest(t.words) w where private.fold(e.destination) not like '%' || w || '%'))))
  ), tot as (
    select count(*) as visits,
           count(distinct coalesce(nullif(m.doc_number, ''), nullif(private.fold(m.person_name), ''))) as people,
           count(distinct nullif(m.plate, '')) as vehicles,
           min(m.entered_at) as first_at,
           max(m.entered_at) as last_at
    from m
  )
  select m.id, m.site_id, m.site_name, m.kind, m.plate, m.person_name, m.doc_kind, m.doc_number,
         m.company_name, m.destination, m.status, m.entered_at, m.exited_at,
         pin.full_name, pout.full_name, m.entry_offline, m.exit_offline, m.doc_photo_path,
         tot.visits, tot.people, tot.vehicles, tot.first_at, tot.last_at
  from m
  cross join tot
  left join public.profiles pin on pin.id = m.entered_by
  left join public.profiles pout on pout.id = m.exited_by
  order by m.entered_at desc
  limit greatest(1, least(coalesce(p_limit, 200), 500));
$$;

revoke execute on function public.search_visits(text, uuid, uuid, timestamptz, timestamptz, integer) from public, anon;
grant execute on function public.search_visits(text, uuid, uuid, timestamptz, timestamptz, integer) to authenticated;
