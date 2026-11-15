-- Módulo 2 · Documentos con vencimiento (personas, empresa y clientes), alertas de vencimiento
-- y resumen de empresas para el súper admin.

-- ---------------------------------------------------------------------------
-- Catálogo de tipos de documento: cada empresa tiene el suyo (nace con una plantilla base).
-- ---------------------------------------------------------------------------
create table if not exists public.document_types (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  key text,                                   -- tipos base (p. ej. 'weapon_license'); null en tipos propios
  name text not null,
  applies_to text not null check (applies_to in ('staff', 'company', 'client')),
  roles public.app_role[] not null default '{}',  -- para 'staff': a qué roles aplica
  has_expiry boolean not null default true,       -- exige fecha de vencimiento
  required boolean not null default false,        -- si falta, sale como alerta
  default_validity_months smallint check (default_validity_months between 1 and 120),
  active boolean not null default true,
  sort_order smallint not null default 100,
  created_at timestamptz not null default now(),
  constraint document_types_roles check (
    (applies_to = 'staff' and roles <@ array['company_admin', 'supervisor', 'guard']::public.app_role[])
    or (applies_to <> 'staff' and roles = '{}'))
);

create unique index if not exists document_types_key
  on public.document_types (company_id, key) where key is not null;
create unique index if not exists document_types_name
  on public.document_types (company_id, applies_to, lower(name));

create or replace function private.document_types_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.name := private.norm_text(new.name);
  if new.name is null then
    raise exception 'nombre del tipo de documento requerido' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' and (select auth.uid()) is not null and (
       new.key is distinct from old.key or new.applies_to is distinct from old.applies_to
       or new.company_id is distinct from old.company_id) then
    raise exception 'no se puede cambiar la clave, el uso ni la empresa de un tipo de documento' using errcode = '22023';
  end if;
  if tg_op = 'INSERT' and (select auth.uid()) is not null then
    new.key := null;  -- las claves base las pone solo la plantilla
  end if;
  return new;
end $$;

drop trigger if exists trg_document_types_before_write on public.document_types;
create trigger trg_document_types_before_write before insert or update on public.document_types
  for each row execute function private.document_types_before_write();

alter table public.document_types enable row level security;

drop policy if exists document_types_select on public.document_types;
create policy document_types_select on public.document_types for select to authenticated
  using (private.user_role() = 'super_admin' or company_id = private.user_company());

drop policy if exists document_types_insert on public.document_types;
create policy document_types_insert on public.document_types for insert to authenticated
  with check (private.is_admin_of(company_id));

drop policy if exists document_types_update on public.document_types;
create policy document_types_update on public.document_types for update to authenticated
  using (private.is_admin_of(company_id))
  with check (private.is_admin_of(company_id));

-- Los tipos no se borran (los documentos viejos los usan): se desactivan con active = false.
revoke all on public.document_types from anon;
revoke delete, truncate, trigger, references on public.document_types from authenticated;

-- Plantilla base. Cada empresa puede renombrar, desactivar, marcar obligatorios o agregar los suyos.
create or replace function private.seed_document_types(p_company uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.document_types (company_id, key, name, applies_to, roles, has_expiry, required, sort_order)
  values
    (p_company, 'dpi',                   'DPI',                                     'staff',   '{company_admin,supervisor,guard}', true,  true,  10),
    (p_company, 'digessp_credential',    'Credencial de agente (DIGESSP)',          'staff',   '{supervisor,guard}',               true,  false, 20),
    (p_company, 'weapon_license',        'Licencia de portación de arma (DIGECAM)', 'staff',   '{supervisor,guard}',               true,  false, 30),
    (p_company, 'criminal_record',       'Antecedentes penales',                    'staff',   '{company_admin,supervisor,guard}', true,  false, 40),
    (p_company, 'police_record',         'Antecedentes policíacos',                 'staff',   '{company_admin,supervisor,guard}', true,  false, 50),
    (p_company, 'training',              'Curso de capacitación de agente',         'staff',   '{supervisor,guard}',               false, false, 60),
    (p_company, 'driver_license',        'Licencia de conducir',                    'staff',   '{company_admin,supervisor,guard}', true,  false, 70),
    (p_company, 'digessp_license',       'Licencia de operación (DIGESSP)',         'company', '{}',                               true,  true,  10),
    (p_company, 'legal_rep_appointment', 'Nombramiento del representante legal',    'company', '{}',                               true,  false, 20),
    (p_company, 'commerce_patent',       'Patente de comercio',                     'company', '{}',                               false, false, 30),
    (p_company, 'rtu',                   'RTU (SAT)',                               'company', '{}',                               false, false, 40),
    (p_company, 'digecam_authorization', 'Autorización de armas de la empresa (DIGECAM)', 'company', '{}',                         true,  false, 50),
    (p_company, 'insurance',             'Póliza de seguro o fianza',               'company', '{}',                               true,  false, 60),
    (p_company, 'service_contract',      'Contrato de servicio',                    'client',  '{}',                               false, false, 10)
  on conflict do nothing;
$$;

-- Empresa nueva: suscripción en prueba + catálogo de documentos.
create or replace function private.companies_after_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.company_subscriptions (company_id) values (new.id) on conflict do nothing;
  perform private.seed_document_types(new.id);
  return null;
end $$;

select private.seed_document_types(id) from public.companies;

-- ---------------------------------------------------------------------------
-- Documentos. Se guardan como historial: renovar = agregar uno nuevo; el vigente es el más reciente.
-- Dueño: persona (profile_id), cliente (client_id) o la empresa (ambos vacíos).
-- ---------------------------------------------------------------------------
create table if not exists public.documents (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  type_id uuid not null references public.document_types(id),
  profile_id uuid references public.profiles(id) on delete cascade,
  client_id uuid references public.clients(id) on delete cascade,
  number text,
  issued_on date,
  expires_on date,
  file_path text,
  notes text,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references public.profiles(id) on delete set null,
  constraint documents_one_owner check (profile_id is null or client_id is null),
  constraint documents_dates check (expires_on is null or issued_on is null or expires_on >= issued_on)
);

create index if not exists documents_profile_idx on public.documents (profile_id, type_id) where profile_id is not null;
create index if not exists documents_client_idx on public.documents (client_id, type_id) where client_id is not null;
create index if not exists documents_company_idx on public.documents (company_id, type_id);
create index if not exists documents_expiry_idx on public.documents (company_id, expires_on) where expires_on is not null;

create or replace function private.documents_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  ty public.document_types%rowtype;
  v_owner_company uuid;
begin
  select * into ty from public.document_types where id = new.type_id;
  if not found then
    raise exception 'tipo de documento inválido' using errcode = '22023';
  end if;
  if ty.applies_to = 'staff' then
    if new.profile_id is null or new.client_id is not null then
      raise exception 'este tipo de documento es de una persona' using errcode = '22023';
    end if;
    select p.company_id into v_owner_company from public.profiles p
     where p.id = new.profile_id and p.role in ('company_admin', 'supervisor', 'guard');
    if v_owner_company is null then
      raise exception 'esa persona no lleva documentos de personal' using errcode = '22023';
    end if;
  elsif ty.applies_to = 'client' then
    if new.client_id is null or new.profile_id is not null then
      raise exception 'este tipo de documento es de un cliente' using errcode = '22023';
    end if;
    select c.company_id into v_owner_company from public.clients c where c.id = new.client_id;
  else
    if new.client_id is not null or new.profile_id is not null then
      raise exception 'este tipo de documento es de la empresa' using errcode = '22023';
    end if;
    v_owner_company := coalesce(new.company_id, ty.company_id);
  end if;
  if v_owner_company is distinct from ty.company_id then
    raise exception 'el tipo de documento pertenece a otra empresa' using errcode = '22023';
  end if;
  new.company_id := ty.company_id;
  new.number := private.norm_text(new.number);
  new.notes := private.norm_text(new.notes);
  if ty.has_expiry and new.expires_on is null then
    raise exception 'este documento requiere fecha de vencimiento' using errcode = '22023';
  end if;
  if new.file_path is not null and new.file_path not like (ty.company_id::text || '/' || new.id::text || '/%') then
    raise exception 'ruta de archivo inválida' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' then
    if new.type_id is distinct from old.type_id or new.profile_id is distinct from old.profile_id
       or new.client_id is distinct from old.client_id or new.id is distinct from old.id then
      raise exception 'no se puede cambiar el tipo ni el dueño de un documento: agregue uno nuevo' using errcode = '22023';
    end if;
    new.created_at := old.created_at;
    new.created_by := old.created_by;
    new.updated_at := now();
    new.updated_by := (select auth.uid());
  end if;
  return new;
end $$;

drop trigger if exists trg_documents_before_write on public.documents;
create trigger trg_documents_before_write before insert or update on public.documents
  for each row execute function private.documents_before_write();

-- Quién ve / quién edita un documento, según su dueño.
create or replace function private.doc_visible(p_profile uuid, p_client uuid, p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(case
    when p_profile is not null then private.can_view_hr(p_profile)
    when p_client is not null then private.is_admin_of(p_company)
         or (private.user_role() = 'client' and p_client = private.user_client())
    else private.is_admin_of(p_company) end, false)
$$;

create or replace function private.doc_editable(p_profile uuid, p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(case
    when p_profile is not null then private.can_edit_person(p_profile)
    else private.is_admin_of(p_company) end, false)
$$;

alter table public.documents enable row level security;

drop policy if exists documents_select on public.documents;
create policy documents_select on public.documents for select to authenticated
  using (private.doc_visible(profile_id, client_id, company_id));

drop policy if exists documents_insert on public.documents;
create policy documents_insert on public.documents for insert to authenticated
  with check (private.doc_editable(profile_id, company_id));

drop policy if exists documents_update on public.documents;
create policy documents_update on public.documents for update to authenticated
  using (private.doc_editable(profile_id, company_id))
  with check (private.doc_editable(profile_id, company_id));

drop policy if exists documents_delete on public.documents;
create policy documents_delete on public.documents for delete to authenticated
  using (private.doc_editable(profile_id, company_id));

revoke all on public.documents from anon;
revoke truncate, trigger, references on public.documents from authenticated;

-- ---------------------------------------------------------------------------
-- Alertas de documentos: vencidos, por vencer (p_days) y obligatorios que faltan.
-- No devuelve número ni archivo: el supervisor solo ve el estado de sus guardas.
--   admin / súper admin: todo el personal + empresa + clientes (incluye fin de contrato).
--   supervisor: sus guardas y él mismo. guarda: él mismo. cliente y usuario: nada.
--   súper admin con p_company vacío: documentos de empresa de todas las empresas activas.
-- ---------------------------------------------------------------------------
create or replace function public.document_alerts(p_company uuid default null, p_days integer default 30)
returns table (
  company_id uuid, owner_kind text, owner_id uuid, owner_name text, owner_role public.app_role,
  type_id uuid, type_key text, type_name text,
  document_id uuid, expires_on date, days_left integer, status text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_role public.app_role := private.user_role();
  v_uid uuid := (select auth.uid());
  v_admin boolean;
  v_limit date := current_date + least(greatest(coalesce(p_days, 30), 0), 365);
begin
  if v_role is null then
    raise exception 'no autorizado' using errcode = '42501';
  end if;

  -- Vista de plataforma (súper admin): documentos de empresa por vencer en todas las empresas.
  if p_company is null then
    if v_role is distinct from 'super_admin' then
      raise exception 'indique la empresa' using errcode = '22023';
    end if;
    return query
    with cur as (
      select distinct on (d.company_id, d.type_id) d.*
      from public.documents d
      where d.profile_id is null and d.client_id is null
      order by d.company_id, d.type_id, coalesce(d.expires_on, 'infinity'::date) desc, d.created_at desc)
    select c.id, 'company'::text, c.id, c.name, null::public.app_role, t.id, t.key, t.name,
           cur.id, cur.expires_on, (cur.expires_on - current_date)::integer,
           case when cur.id is null then 'missing' when cur.expires_on < current_date then 'expired' else 'expiring' end
    from public.companies c
    join public.document_types t on t.company_id = c.id and t.applies_to = 'company' and t.active
    left join cur on cur.company_id = c.id and cur.type_id = t.id
    where c.active
      and ((cur.id is null and t.required) or (cur.expires_on is not null and cur.expires_on <= v_limit))
    order by 11 nulls first, 4, 8;
    return;
  end if;

  v_admin := private.is_admin_of(p_company);
  if not (v_admin or private.user_company() = p_company) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  if v_role in ('client', 'resident') then
    return;
  end if;

  return query
  with people as (
    select p.id, p.full_name, p.role
    from public.profiles p
    where p.company_id = p_company and p.active
      and p.role in ('company_admin', 'supervisor', 'guard')
      and (v_admin or p.id = v_uid or private.supervises_guard(p.id))
  ),
  staff_cur as (
    select distinct on (d.profile_id, d.type_id) d.*
    from public.documents d
    join people pe on pe.id = d.profile_id
    order by d.profile_id, d.type_id, coalesce(d.expires_on, 'infinity'::date) desc, d.created_at desc
  ),
  staff_rows as (
    -- documentos existentes que vencen dentro del plazo (o ya vencieron)
    select pe.id as o_id, pe.full_name as o_name, pe.role as o_role, t.id as t_id, t.key as t_key, t.name as t_name,
           sc.id as d_id, sc.expires_on as d_exp
    from staff_cur sc
    join people pe on pe.id = sc.profile_id
    join public.document_types t on t.id = sc.type_id and t.active
    where sc.expires_on is not null and sc.expires_on <= v_limit
    union all
    -- obligatorios que faltan según el rol
    select pe.id, pe.full_name, pe.role, t.id, t.key, t.name, null::uuid, null::date
    from people pe
    join public.document_types t on t.company_id = p_company and t.applies_to = 'staff'
         and t.active and t.required and pe.role = any (t.roles)
    where not exists (select 1 from staff_cur sc where sc.profile_id = pe.id and sc.type_id = t.id)
  ),
  company_cur as (
    select distinct on (d.type_id) d.*
    from public.documents d
    where v_admin and d.company_id = p_company and d.profile_id is null and d.client_id is null
    order by d.type_id, coalesce(d.expires_on, 'infinity'::date) desc, d.created_at desc
  ),
  company_rows as (
    select co.id as o_id, co.name as o_name, t.id as t_id, t.key as t_key, t.name as t_name, cc.id as d_id, cc.expires_on as d_exp
    from public.companies co
    join public.document_types t on t.company_id = co.id and t.applies_to = 'company' and t.active
    left join company_cur cc on cc.type_id = t.id
    where v_admin and co.id = p_company
      and ((cc.id is null and t.required) or (cc.expires_on is not null and cc.expires_on <= v_limit))
  ),
  client_cur as (
    select distinct on (d.client_id, d.type_id) d.*
    from public.documents d
    where v_admin and d.company_id = p_company and d.client_id is not null
    order by d.client_id, d.type_id, coalesce(d.expires_on, 'infinity'::date) desc, d.created_at desc
  ),
  client_rows as (
    select cl.id as o_id, cl.name as o_name, t.id as t_id, t.key as t_key, t.name as t_name, cc.id as d_id, cc.expires_on as d_exp
    from client_cur cc
    join public.clients cl on cl.id = cc.client_id and cl.active
    join public.document_types t on t.id = cc.type_id and t.active
    where cc.expires_on is not null and cc.expires_on <= v_limit
    union all
    -- fin de contrato del cliente
    select cl.id, cl.name, null::uuid, 'contract_end'::text, 'Fin de contrato'::text, null::uuid, cl.contract_end
    from public.clients cl
    where v_admin and cl.company_id = p_company and cl.active
      and cl.contract_end is not null and cl.contract_end <= v_limit
  ),
  all_rows as (
    select 'staff'::text as kind, r.o_id, r.o_name, r.o_role, r.t_id, r.t_key, r.t_name, r.d_id, r.d_exp from staff_rows r
    union all
    select 'company', r.o_id, r.o_name, null::public.app_role, r.t_id, r.t_key, r.t_name, r.d_id, r.d_exp from company_rows r
    union all
    select 'client', r.o_id, r.o_name, null::public.app_role, r.t_id, r.t_key, r.t_name, r.d_id, r.d_exp from client_rows r
  )
  select p_company, a.kind, a.o_id, a.o_name, a.o_role, a.t_id, a.t_key, a.t_name, a.d_id, a.d_exp,
         (a.d_exp - current_date)::integer,
         case when a.d_exp is null then 'missing' when a.d_exp < current_date then 'expired' else 'expiring' end
  from all_rows a
  order by (a.d_exp - current_date) nulls first, a.o_name, a.t_name;
end $$;

revoke execute on function public.document_alerts(uuid, integer) from public, anon;
grant execute on function public.document_alerts(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Resumen de empresas (pantalla del súper admin). Respeta RLS: cada quien ve lo suyo.
-- ---------------------------------------------------------------------------
create or replace view public.company_summary with (security_invoker = true) as
select c.id, c.name, c.legal_name, c.nit, c.code, c.active, c.created_at,
       s.status as subscription_status, s.plan, s.monthly_fee, s.currency,
       (select count(*) from public.sites x where x.company_id = c.id and x.active) as sites_count,
       (select count(*) from public.clients x where x.company_id = c.id and x.active) as clients_count,
       (select count(*) from public.profiles x where x.company_id = c.id and x.active and x.role = 'guard') as guards_count,
       (select count(*) from public.profiles x where x.company_id = c.id and x.active and x.role = 'supervisor') as supervisors_count,
       lic.number as digessp_license_number,
       lic.expires_on as digessp_license_expires_on
from public.companies c
left join public.company_subscriptions s on s.company_id = c.id
left join lateral (
  select d.number, d.expires_on
  from public.documents d
  join public.document_types t on t.id = d.type_id and t.key = 'digessp_license'
  where d.company_id = c.id and d.profile_id is null and d.client_id is null
  order by coalesce(d.expires_on, 'infinity'::date) desc, d.created_at desc
  limit 1) lic on true;

revoke all on public.company_summary from anon;
revoke all on public.company_summary from authenticated;
grant select on public.company_summary to authenticated;
