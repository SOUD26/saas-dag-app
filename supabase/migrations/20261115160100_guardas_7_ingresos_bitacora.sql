-- Módulo del guarda (7): ingresos y salidas (módulo de pago "control de visitas") y bitácora de novedades.
-- * Ingreso: placa y DPI/licencia que el teléfono lee de la foto (la foto NO se guarda: solo el texto),
--   empresa elegida de una lista, fecha y hora automáticas. Queda "dentro" hasta que se marca la salida.
-- * Solo en sitios con control de visitas (sites.visitor_control, que exige el módulo "ingresos").
-- * El guarda ve los que están dentro con los últimos 4 dígitos del documento; el número completo lo
--   ven el administrador y el supervisor del sitio.
-- * Bitácora de novedades: para todos los sitios. "Incidente" crea una alerta naranja.
-- * Todo trae id del teléfono (no se duplica) y su hora (marca "sin conexión" si llegó tarde).

-- ---------- Empresas que visitan (lista para elegir) ----------
create table public.visitor_companies (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  active boolean not null default true,
  sort_order smallint not null default 100,
  created_at timestamptz not null default now()
);
create unique index visitor_companies_name_uq on public.visitor_companies (company_id, lower(name));

create or replace function private.visitor_companies_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.name := private.norm_text(new.name);
  if new.name is null then
    raise exception 'escribe el nombre de la empresa' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' and new.company_id is distinct from old.company_id then
    raise exception 'no se cambia de empresa' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger trg_visitor_companies_before_write before insert or update on public.visitor_companies
  for each row execute function private.visitor_companies_before_write();
create trigger trg_audit_visitor_companies after insert or update on public.visitor_companies
  for each row execute function private.audit_changes('visitor_company', '', 'true');

alter table public.visitor_companies enable row level security;
create policy visitor_companies_select on public.visitor_companies for select to authenticated
  using (private.user_role() = 'super_admin'
         or (company_id = private.user_company()
             and private.user_role() in ('company_admin', 'supervisor', 'guard')));
-- La lista la llevan el administrador y los supervisores de la empresa.
create policy visitor_companies_insert on public.visitor_companies for insert to authenticated
  with check (private.is_admin_of(company_id)
              or (private.user_role() = 'supervisor' and company_id = private.user_company()));
create policy visitor_companies_update on public.visitor_companies for update to authenticated
  using (private.is_admin_of(company_id)
         or (private.user_role() = 'supervisor' and company_id = private.user_company()))
  with check (private.is_admin_of(company_id)
              or (private.user_role() = 'supervisor' and company_id = private.user_company()));
revoke all on public.visitor_companies from anon;
revoke delete, truncate, references, trigger on public.visitor_companies from authenticated;

create or replace function private.seed_visitor_companies(p_company uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.visitor_companies (company_id, name, sort_order)
  values
    (p_company, 'Visita personal', 1),
    (p_company, 'Proveedor', 2),
    (p_company, 'Mantenimiento', 3),
    (p_company, 'Servicio técnico', 4),
    (p_company, 'Taxi o transporte', 5),
    (p_company, 'Mudanza', 6),
    (p_company, 'Cargo Expreso', 20),
    (p_company, 'Guatex', 21),
    (p_company, 'Forza Delivery', 22),
    (p_company, 'DHL', 23),
    (p_company, 'FedEx', 24),
    (p_company, 'PedidosYa', 25),
    (p_company, 'Hugo', 26),
    (p_company, 'Claro', 27),
    (p_company, 'Tigo', 28),
    (p_company, 'EEGSA', 29),
    (p_company, 'Empagua', 30)
  on conflict do nothing;
end $$;

create or replace function private.companies_after_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.company_subscriptions (company_id) values (new.id) on conflict do nothing;
  perform private.seed_document_types(new.id);
  perform private.seed_implement_types(new.id);
  perform private.seed_visitor_companies(new.id);
  return null;
end $$;

select private.seed_visitor_companies(id) from public.companies;

-- ---------- Ingresos y salidas ----------
create table public.access_entries (
  id uuid primary key,                      -- lo crea el teléfono
  company_id uuid not null references public.companies(id) on delete cascade,
  site_id uuid not null references public.sites(id) on delete cascade,
  post_id uuid references public.site_posts(id) on delete set null,
  kind text not null check (kind in ('vehicle', 'motorcycle', 'pedestrian')),
  plate text,                               -- solo letras y números: P123ABC
  person_name text,
  doc_kind text check (doc_kind in ('dpi', 'license', 'passport', 'other')),
  doc_number text,
  visitor_company_id uuid references public.visitor_companies(id) on delete set null,
  visitor_company_text text,                -- "Otra": la escribió el guarda
  destination text,                         -- a dónde va (casa, oficina, bodega)
  notes text,
  status text not null default 'inside' check (status in ('inside', 'exited')),
  entered_at timestamptz not null,
  entered_by uuid references public.profiles(id) on delete set null,
  entry_device_id uuid references public.devices(id) on delete set null,
  entry_offline boolean not null default false,
  exited_at timestamptz,
  exited_by uuid references public.profiles(id) on delete set null,
  exit_device_id uuid references public.devices(id) on delete set null,
  exit_offline boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  constraint access_entries_exit_ck check ((status = 'exited') = (exited_at is not null))
);
create index access_entries_inside_idx on public.access_entries (site_id) where status = 'inside';
create index access_entries_site_idx on public.access_entries (site_id, entered_at desc);
create index access_entries_plate_idx on public.access_entries (company_id, plate);

alter table public.access_entries enable row level security;
-- El número completo de documento solo lo ven el administrador y el supervisor del sitio.
-- El guarda usa site_inside(), que muestra los últimos 4 dígitos.
create policy access_entries_select on public.access_entries for select to authenticated
  using (private.is_admin_of(company_id)
         or (private.user_role() = 'supervisor' and private.sees_site(site_id)));
revoke all on public.access_entries from anon;
revoke insert, update, delete, truncate, references, trigger on public.access_entries from authenticated;

create or replace function public.register_entry(
  p_id uuid, p_site_id uuid, p_post_id uuid, p_data jsonb,
  p_happened_at timestamptz default null, p_device_id uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_site public.sites%rowtype;
  v_old public.access_entries%rowtype;
  v_kind text;
  v_plate text;
  v_doc_kind text;
  v_doc text;
  v_name text;
  v_vc uuid;
begin
  if p_id is null or p_data is null or jsonb_typeof(p_data) <> 'object' then
    raise exception 'datos inválidos' using errcode = '22023';
  end if;
  select * into v_old from public.access_entries where id = p_id;
  if found then
    if v_old.entered_by is distinct from v_uid then
      raise exception 'no autorizado' using errcode = '42501';
    end if;
    return p_id;                          -- ya había llegado: no se duplica
  end if;
  if private.user_role() is distinct from 'guard' then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  select s.* into v_site from public.sites s
    join public.guard_sites gs on gs.site_id = s.id
   where s.id = p_site_id and s.active and gs.guard_id = v_uid and gs.active;
  if not found then
    raise exception 'guarda no asignado a este sitio' using errcode = '42501';
  end if;
  if not v_site.visitor_control then
    raise exception 'el control de visitas no está activo en este sitio' using errcode = '22023';
  end if;
  if p_post_id is not null and not exists (
       select 1 from public.site_posts p where p.id = p_post_id and p.site_id = p_site_id) then
    raise exception 'puesto inválido' using errcode = '22023';
  end if;
  if p_device_id is not null and not exists (
       select 1 from public.devices d where d.id = p_device_id and d.site_id = p_site_id and d.active) then
    raise exception 'teléfono no vinculado a este sitio' using errcode = '42501';
  end if;

  v_kind := coalesce(p_data ->> 'kind', 'vehicle');
  if v_kind not in ('vehicle', 'motorcycle', 'pedestrian') then
    raise exception 'tipo de ingreso inválido' using errcode = '22023';
  end if;
  v_plate := nullif(upper(regexp_replace(coalesce(p_data ->> 'plate', ''), '[^A-Za-z0-9]', '', 'g')), '');
  if v_kind <> 'pedestrian' and (v_plate is null or length(v_plate) < 4 or length(v_plate) > 10) then
    raise exception 'escribe la placa' using errcode = '22023';
  end if;
  v_doc_kind := nullif(p_data ->> 'doc_kind', '');
  if v_doc_kind is not null and v_doc_kind not in ('dpi', 'license', 'passport', 'other') then
    raise exception 'tipo de documento inválido' using errcode = '22023';
  end if;
  v_doc := nullif(upper(regexp_replace(coalesce(p_data ->> 'doc_number', ''), '[^A-Za-z0-9]', '', 'g')), '');
  v_name := left(private.norm_text(p_data ->> 'person_name'), 120);
  if v_kind = 'pedestrian' and v_name is null and v_doc is null then
    raise exception 'escribe el nombre o el documento de la persona' using errcode = '22023';
  end if;
  v_vc := private.try_uuid(p_data ->> 'visitor_company_id');
  if v_vc is not null and not exists (
       select 1 from public.visitor_companies vc where vc.id = v_vc and vc.company_id = v_site.company_id) then
    v_vc := null;
  end if;

  insert into public.access_entries (id, company_id, site_id, post_id, kind, plate, person_name, doc_kind,
                                     doc_number, visitor_company_id, visitor_company_text, destination, notes,
                                     entered_at, entered_by, entry_device_id, entry_offline)
  values (p_id, v_site.company_id, p_site_id, p_post_id, v_kind, v_plate, v_name,
          case when v_doc is null then null else coalesce(v_doc_kind, 'other') end, left(v_doc, 30),
          v_vc, case when v_vc is null then left(private.norm_text(p_data ->> 'visitor_company_text'), 80) end,
          left(private.norm_text(p_data ->> 'destination'), 200), left(private.norm_text(p_data ->> 'notes'), 500),
          private.device_time(p_happened_at), v_uid, p_device_id, private.is_offline(p_happened_at));
  return p_id;
end $$;

create or replace function public.register_exit(
  p_id uuid, p_happened_at timestamptz default null, p_device_id uuid default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v public.access_entries%rowtype;
begin
  select * into v from public.access_entries where id = p_id for update;
  if not found then
    raise exception 'ingreso no encontrado' using errcode = '22023';
  end if;
  if not coalesce(
       private.is_admin_of(v.company_id)
       or (private.user_role() = 'supervisor' and private.sees_site(v.site_id))
       or (private.user_role() = 'guard' and exists (
             select 1 from public.guard_sites gs where gs.site_id = v.site_id and gs.guard_id = v_uid and gs.active)),
       false) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  if v.status = 'exited' then
    return;                               -- ya tenía salida: no se cambia
  end if;
  update public.access_entries
     set status = 'exited',
         exited_at = greatest(private.device_time(p_happened_at), v.entered_at),
         exited_by = v_uid, exit_device_id = p_device_id, exit_offline = private.is_offline(p_happened_at),
         updated_at = now()
   where id = p_id;
end $$;

-- Los que siguen dentro (para el guarda: documento con los últimos 4 dígitos).
create or replace function public.site_inside(p_site_id uuid)
returns table (id uuid, kind text, plate text, person_name text, doc_kind text, doc_last4 text,
               company_name text, destination text, entered_at timestamptz, entered_by_name text,
               entry_offline boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.sees_site(p_site_id)
     or coalesce(private.user_role()::text, '') not in ('super_admin', 'company_admin', 'supervisor', 'guard') then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  return query
    select e.id, e.kind, e.plate, e.person_name, e.doc_kind, right(e.doc_number, 4),
           coalesce(vc.name, e.visitor_company_text), e.destination, e.entered_at, p.full_name, e.entry_offline
    from public.access_entries e
    left join public.visitor_companies vc on vc.id = e.visitor_company_id
    left join public.profiles p on p.id = e.entered_by
    where e.site_id = p_site_id and e.status = 'inside'
    order by e.entered_at desc;
end $$;

-- ---------- Bitácora de novedades ----------
create table public.site_log (
  id uuid primary key,                      -- lo crea el teléfono
  company_id uuid not null references public.companies(id) on delete cascade,
  site_id uuid not null references public.sites(id) on delete cascade,
  post_id uuid references public.site_posts(id) on delete set null,
  author_id uuid references public.profiles(id) on delete set null,
  category text not null check (category in ('sin_novedad', 'novedad', 'incidente', 'mantenimiento', 'visita_supervisor')),
  body text check (body is null or length(body) <= 2000),
  happened_at timestamptz not null,
  offline boolean not null default false,
  device_id uuid references public.devices(id) on delete set null,
  created_at timestamptz not null default now()
);
create index site_log_site_idx on public.site_log (site_id, happened_at desc);

alter table public.site_log enable row level security;
-- El guarda lee las novedades de sus sitios de los últimos 3 días (para saber qué pasó en el turno anterior).
create policy site_log_select on public.site_log for select to authenticated
  using (private.is_admin_of(company_id)
         or (private.user_role() = 'supervisor' and private.sees_site(site_id))
         or (private.user_role() = 'guard' and private.sees_site(site_id)
             and happened_at > now() - interval '3 days'));
revoke all on public.site_log from anon;
revoke insert, update, delete, truncate, references, trigger on public.site_log from authenticated;

create or replace function public.add_log_entry(
  p_id uuid, p_site_id uuid, p_post_id uuid, p_category text, p_body text,
  p_happened_at timestamptz default null, p_device_id uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_role public.app_role := private.user_role();
  v_site public.sites%rowtype;
  v_old public.site_log%rowtype;
  v_body text := nullif(btrim(coalesce(p_body, '')), '');
begin
  if p_id is null then
    raise exception 'falta el identificador' using errcode = '22023';
  end if;
  select * into v_old from public.site_log where id = p_id;
  if found then
    if v_old.author_id is distinct from v_uid then
      raise exception 'no autorizado' using errcode = '42501';
    end if;
    return p_id;
  end if;
  select * into v_site from public.sites where id = p_site_id and active;
  if not found or not coalesce(
       (v_role = 'guard' and exists (select 1 from public.guard_sites gs
                                     where gs.site_id = p_site_id and gs.guard_id = v_uid and gs.active))
       or (v_role = 'supervisor' and private.sees_site(p_site_id)), false) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  if p_category is null or p_category not in ('sin_novedad', 'novedad', 'incidente', 'mantenimiento', 'visita_supervisor') then
    raise exception 'tipo de novedad inválido' using errcode = '22023';
  end if;
  if p_category in ('novedad', 'incidente', 'mantenimiento') and v_body is null then
    raise exception 'escribe qué pasó' using errcode = '22023';
  end if;
  if p_post_id is not null and not exists (
       select 1 from public.site_posts p where p.id = p_post_id and p.site_id = p_site_id) then
    raise exception 'puesto inválido' using errcode = '22023';
  end if;
  if p_device_id is not null and not exists (
       select 1 from public.devices d where d.id = p_device_id and d.site_id = p_site_id and d.active) then
    raise exception 'teléfono no vinculado a este sitio' using errcode = '42501';
  end if;

  insert into public.site_log (id, company_id, site_id, post_id, author_id, category, body, happened_at, offline, device_id)
  values (p_id, v_site.company_id, p_site_id, p_post_id, v_uid, p_category, left(v_body, 2000),
          private.device_time(p_happened_at), private.is_offline(p_happened_at), p_device_id);

  if p_category = 'incidente' then
    insert into public.alerts (company_id, site_id, post_id, guard_id, source, source_id, severity, title, detail)
    values (v_site.company_id, p_site_id, p_post_id, case when v_role = 'guard' then v_uid end,
            'other', p_id, 'orange', 'Incidente reportado', left(v_body, 500));
  end if;
  return p_id;
end $$;

revoke execute on function public.register_entry(uuid, uuid, uuid, jsonb, timestamptz, uuid) from public, anon;
revoke execute on function public.register_exit(uuid, timestamptz, uuid) from public, anon;
revoke execute on function public.site_inside(uuid) from public, anon;
revoke execute on function public.add_log_entry(uuid, uuid, uuid, text, text, timestamptz, uuid) from public, anon;
grant execute on function public.register_entry(uuid, uuid, uuid, jsonb, timestamptz, uuid) to authenticated;
grant execute on function public.register_exit(uuid, timestamptz, uuid) to authenticated;
grant execute on function public.site_inside(uuid) to authenticated;
grant execute on function public.add_log_entry(uuid, uuid, uuid, text, text, timestamptz, uuid) to authenticated;

-- DATOS DE DEMOSTRACIÓN: la empresa demo tiene el módulo de ingresos y los sitios Demo el control de visitas.
insert into public.company_modules (company_id, module, enabled)
select id, 'ingresos', true from public.companies where code = 'C2193E'
on conflict do nothing;
update public.sites set visitor_control = true where name like 'Demo · %';
