-- =====================================================================
-- SaaS-DAG · Módulo 1: empresas, usuarios, roles, permisos, caras, verificaciones
-- =====================================================================
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create type public.app_role as enum ('super_admin','company_admin','supervisor','guard','client');

-- ---------- Tablas ----------
create table public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.clients (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  company_id uuid references public.companies(id) on delete restrict,
  client_id uuid references public.clients(id) on delete restrict,
  role public.app_role not null,
  full_name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint profiles_company_ck check ((role = 'super_admin') = (company_id is null)),
  constraint profiles_client_ck check ((role = 'client') = (client_id is not null))
);

create table public.company_modules (
  company_id uuid not null references public.companies(id) on delete cascade,
  module text not null,
  enabled boolean not null default false,
  primary key (company_id, module)
);

create table public.sites (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  client_id uuid references public.clients(id) on delete set null,
  name text not null,
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  radius_m integer not null default 100 check (radius_m between 10 and 5000),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.devices (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  site_id uuid not null references public.sites(id) on delete cascade,
  label text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.guard_sites (
  guard_id uuid not null references public.profiles(id) on delete cascade,
  site_id uuid not null references public.sites(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  active boolean not null default true,
  primary key (guard_id, site_id)
);

create table public.supervisor_sites (
  supervisor_id uuid not null references public.profiles(id) on delete cascade,
  site_id uuid not null references public.sites(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  primary key (supervisor_id, site_id)
);

-- Catálogo de permisos otorgables por el administrador (casillas del panel de control)
create table public.permissions (
  key text primary key,
  description text not null,
  grantable_to public.app_role[] not null
);
insert into public.permissions (key, description, grantable_to) values
  ('caras.gestionar', 'Registrar y quitar el reconocimiento facial de los guardas de sus sitios', '{supervisor}');

create table public.user_permissions (
  user_id uuid not null references public.profiles(id) on delete cascade,
  permission text not null references public.permissions(key) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  granted_by uuid references public.profiles(id) on delete set null,
  granted_at timestamptz not null default now(),
  primary key (user_id, permission)
);

create table public.face_templates (
  guard_id uuid primary key references public.profiles(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  embedding real[] not null check (cardinality(embedding) between 64 and 1024),
  model_version text not null,
  consent_signed_at timestamptz not null,
  enrolled_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Bitácora inmutable (sin FK a propósito: conserva historia)
create table public.audit_log (
  id bigint generated always as identity primary key,
  company_id uuid,
  actor uuid,
  action text not null,
  target_user uuid,
  detail text,
  at timestamptz not null default now()
);

create table public.shift_verifications (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  guard_id uuid not null references public.profiles(id) on delete cascade,
  site_id uuid not null references public.sites(id) on delete cascade,
  device_id uuid references public.devices(id) on delete set null,
  kind text not null check (kind in ('shift_start','random_check')),
  method text not null check (method in ('face','password_fallback','face_rejected')),
  face_score real,
  matched_guard_id uuid references public.profiles(id) on delete set null,
  lat double precision,
  lng double precision,
  distance_m real,
  within_perimeter boolean not null,
  flagged boolean not null default false,
  flag_reason text,
  photo_path text,
  created_at timestamptz not null default now()
);

create index on public.profiles (company_id);
create index on public.clients (company_id);
create index on public.sites (company_id);
create index on public.sites (client_id);
create index on public.devices (site_id);
create index on public.guard_sites (site_id);
create index on public.supervisor_sites (site_id);
create index on public.user_permissions (company_id);
create index on public.audit_log (company_id, at desc);
create index on public.shift_verifications (site_id, created_at desc);
create index on public.shift_verifications (guard_id, created_at desc);
create index on public.shift_verifications (company_id);

-- ---------- Funciones de apoyo (schema privado) ----------
create function private.user_role() returns public.app_role
language sql stable security definer set search_path = '' as $$
  select p.role from public.profiles p
  left join public.companies c on c.id = p.company_id
  where p.id = (select auth.uid()) and p.active and (p.company_id is null or c.active)
$$;

create function private.user_company() returns uuid
language sql stable security definer set search_path = '' as $$
  select p.company_id from public.profiles p
  left join public.companies c on c.id = p.company_id
  where p.id = (select auth.uid()) and p.active and (p.company_id is null or c.active)
$$;

create function private.user_client() returns uuid
language sql stable security definer set search_path = '' as $$
  select p.client_id from public.profiles p
  where p.id = (select auth.uid()) and p.active
$$;

create function private.is_admin_of(p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    private.user_role() = 'super_admin'
    or (private.user_role() = 'company_admin' and private.user_company() = p_company),
    false)
$$;

create function private.sees_site(p_site uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.sites s where s.id = p_site and (
      private.is_admin_of(s.company_id)
      or (private.user_role() = 'supervisor' and exists (
            select 1 from public.supervisor_sites ss
            where ss.site_id = s.id and ss.supervisor_id = (select auth.uid())))
      or (private.user_role() = 'guard' and exists (
            select 1 from public.guard_sites gs
            where gs.site_id = s.id and gs.guard_id = (select auth.uid()) and gs.active))
      or (private.user_role() = 'client' and s.client_id is not null and s.client_id = private.user_client())
    ))
$$;

create function private.supervises_guard(p_guard uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.user_role() = 'supervisor' and exists (
    select 1 from public.guard_sites gs
    join public.supervisor_sites ss on ss.site_id = gs.site_id
    where gs.guard_id = p_guard and ss.supervisor_id = (select auth.uid()))
$$;

create function private.profile_in(p_id uuid, p_company uuid, p_role public.app_role) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = p_id and company_id = p_company and role = p_role)
$$;

create function private.site_in(p_site uuid, p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.sites where id = p_site and company_id = p_company)
$$;

create function private.can_grant(p_user uuid, p_perm text, p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles pr
    join public.permissions pm on pm.key = p_perm
    where pr.id = p_user and pr.company_id = p_company and pr.role = any (pm.grantable_to))
$$;

-- Quién puede registrar/quitar la cara de un guarda:
-- el Admin de la empresa, o un Supervisor con el permiso 'caras.gestionar' y solo sobre guardas de sus sitios.
-- El súper admin (proveedor) NO tiene acceso a datos biométricos.
create function private.can_manage_face_of(p_guard uuid, p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (
      (private.user_role() = 'company_admin' and private.user_company() = p_company)
      or (
        private.user_role() = 'supervisor' and private.user_company() = p_company
        and exists (select 1 from public.user_permissions up
                    where up.user_id = (select auth.uid()) and up.permission = 'caras.gestionar')
        and private.supervises_guard(p_guard)
      )
    )
    and private.profile_in(p_guard, p_company, 'guard'),
    false)
$$;

-- ---------- Bitácora automática ----------
create function private.audit_face() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.audit_log (company_id, actor, action, target_user)
    values (new.company_id, (select auth.uid()), 'face_enrolled', new.guard_id);
    return new;
  else
    insert into public.audit_log (company_id, actor, action, target_user)
    values (old.company_id, (select auth.uid()), 'face_removed', old.guard_id);
    return old;
  end if;
end $$;
create trigger trg_audit_face after insert or delete on public.face_templates
  for each row execute function private.audit_face();

create function private.audit_permission() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.audit_log (company_id, actor, action, target_user, detail)
    values (new.company_id, (select auth.uid()), 'permission_granted', new.user_id, new.permission);
    return new;
  else
    insert into public.audit_log (company_id, actor, action, target_user, detail)
    values (old.company_id, (select auth.uid()), 'permission_revoked', old.user_id, old.permission);
    return old;
  end if;
end $$;
create trigger trg_audit_permission after insert or delete on public.user_permissions
  for each row execute function private.audit_permission();

create function private.audit_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.active is distinct from old.active then
    insert into public.audit_log (company_id, actor, action, target_user)
    values (new.company_id, (select auth.uid()),
            case when new.active then 'user_activated' else 'user_deactivated' end, new.id);
  end if;
  if new.role is distinct from old.role then
    insert into public.audit_log (company_id, actor, action, target_user, detail)
    values (new.company_id, (select auth.uid()), 'role_changed', new.id, old.role::text || ' -> ' || new.role::text);
  end if;
  return new;
end $$;
create trigger trg_audit_profile after update on public.profiles
  for each row execute function private.audit_profile();

-- ---------- RLS ----------
alter table public.companies          enable row level security;
alter table public.clients            enable row level security;
alter table public.profiles           enable row level security;
alter table public.company_modules    enable row level security;
alter table public.sites              enable row level security;
alter table public.devices            enable row level security;
alter table public.guard_sites        enable row level security;
alter table public.supervisor_sites   enable row level security;
alter table public.permissions        enable row level security;
alter table public.user_permissions   enable row level security;
alter table public.face_templates     enable row level security;
alter table public.audit_log          enable row level security;
alter table public.shift_verifications enable row level security;

-- companies
create policy companies_select on public.companies for select to authenticated
  using (private.user_role() = 'super_admin' or id = private.user_company());
create policy companies_write on public.companies for all to authenticated
  using (private.user_role() = 'super_admin') with check (private.user_role() = 'super_admin');

-- company_modules (solo el súper admin activa módulos; la empresa los ve)
create policy modules_select on public.company_modules for select to authenticated
  using (private.user_role() = 'super_admin' or company_id = private.user_company());
create policy modules_write on public.company_modules for all to authenticated
  using (private.user_role() = 'super_admin') with check (private.user_role() = 'super_admin');

-- clients
create policy clients_select on public.clients for select to authenticated
  using (private.is_admin_of(company_id)
         or (private.user_role() = 'client' and id = private.user_client()));
create policy clients_write on public.clients for all to authenticated
  using (private.is_admin_of(company_id)) with check (private.is_admin_of(company_id));

-- profiles (nadie inserta ni borra desde la app: se crean con la función de servidor y se desactivan)
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid())
         or private.is_admin_of(company_id)
         or private.supervises_guard(id));
create policy profiles_update on public.profiles for update to authenticated
  using (private.user_role() = 'super_admin'
         or (private.is_admin_of(company_id) and role <> 'super_admin'))
  with check (private.user_role() = 'super_admin'
         or (private.is_admin_of(company_id) and role <> 'super_admin'));

-- sites
create policy sites_select on public.sites for select to authenticated
  using (private.sees_site(id));
create policy sites_write on public.sites for all to authenticated
  using (private.is_admin_of(company_id))
  with check (private.is_admin_of(company_id)
    and (client_id is null or exists (select 1 from public.clients c where c.id = client_id and c.company_id = sites.company_id)));

-- devices
create policy devices_select on public.devices for select to authenticated
  using (private.user_role() <> 'client' and private.sees_site(site_id));
create policy devices_write on public.devices for all to authenticated
  using (private.is_admin_of(company_id))
  with check (private.is_admin_of(company_id) and private.site_in(site_id, company_id));

-- guard_sites
create policy guard_sites_select on public.guard_sites for select to authenticated
  using (private.is_admin_of(company_id)
         or guard_id = (select auth.uid())
         or (private.user_role() = 'supervisor' and private.sees_site(site_id)));
create policy guard_sites_write on public.guard_sites for all to authenticated
  using (private.is_admin_of(company_id))
  with check (private.is_admin_of(company_id)
    and private.site_in(site_id, company_id)
    and private.profile_in(guard_id, company_id, 'guard'));

-- supervisor_sites
create policy supervisor_sites_select on public.supervisor_sites for select to authenticated
  using (private.is_admin_of(company_id) or supervisor_id = (select auth.uid()));
create policy supervisor_sites_write on public.supervisor_sites for all to authenticated
  using (private.is_admin_of(company_id))
  with check (private.is_admin_of(company_id)
    and private.site_in(site_id, company_id)
    and private.profile_in(supervisor_id, company_id, 'supervisor'));

-- permissions (catálogo) y user_permissions
create policy permissions_select on public.permissions for select to authenticated
  using (private.user_role() is not null);

create policy uperm_select on public.user_permissions for select to authenticated
  using (user_id = (select auth.uid()) or private.is_admin_of(company_id));
create policy uperm_insert on public.user_permissions for insert to authenticated
  with check (private.is_admin_of(company_id)
    and granted_by = (select auth.uid())
    and private.can_grant(user_id, permission, company_id));
create policy uperm_delete on public.user_permissions for delete to authenticated
  using (private.is_admin_of(company_id));

-- face_templates: solo Admin de empresa o Supervisor con permiso (y solo sus guardas)
create policy face_select on public.face_templates for select to authenticated
  using (private.can_manage_face_of(guard_id, company_id));
create policy face_insert on public.face_templates for insert to authenticated
  with check (private.can_manage_face_of(guard_id, company_id)
    and enrolled_by = (select auth.uid())
    and consent_signed_at <= now());
create policy face_delete on public.face_templates for delete to authenticated
  using (private.can_manage_face_of(guard_id, company_id));

-- audit_log (solo lectura)
create policy audit_select on public.audit_log for select to authenticated
  using (private.is_admin_of(company_id));

-- shift_verifications (solo lectura; se escribe con register_verification)
create policy verif_select on public.shift_verifications for select to authenticated
  using (private.user_role() is not null and (
    private.is_admin_of(company_id)
    or guard_id = (select auth.uid())
    or (private.user_role() = 'supervisor' and private.sees_site(site_id))));

-- ---------- Privilegios de tabla ----------
revoke all on all tables in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
revoke insert, delete on public.profiles from authenticated;
revoke update on public.profiles from authenticated;
grant update (full_name, role, active, client_id) on public.profiles to authenticated;
revoke update on public.face_templates from authenticated;
revoke update on public.user_permissions from authenticated;
revoke insert, update, delete on public.audit_log from authenticated;
revoke insert, update, delete on public.shift_verifications from authenticated;
revoke insert, update, delete on public.permissions from authenticated;

-- ---------- RPC: plantillas del sitio para el teléfono (comparación 1:N en el dispositivo) ----------
create function public.get_site_face_templates(p_site_id uuid)
returns table (guard_id uuid, embedding real[], model_version text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if private.user_role() is distinct from 'guard'
     or not exists (select 1 from public.guard_sites gs
                    where gs.site_id = p_site_id and gs.guard_id = (select auth.uid()) and gs.active) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  return query
    select ft.guard_id, ft.embedding, ft.model_version
    from public.face_templates ft
    join public.guard_sites gs on gs.guard_id = ft.guard_id and gs.site_id = p_site_id and gs.active
    join public.profiles p on p.id = ft.guard_id and p.active;
end $$;

-- ---------- RPC: registrar verificación (el servidor calcula el perímetro y las banderas) ----------
create function public.register_verification(
  p_site_id uuid, p_device_id uuid, p_kind text, p_method text,
  p_face_score real, p_matched_guard_id uuid,
  p_lat double precision, p_lng double precision,
  p_fallback_reason text, p_photo_path text)
returns table (r_id uuid, r_within boolean, r_flagged boolean, r_reason text)
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_site public.sites%rowtype;
  v_dist double precision;
  v_within boolean;
  v_reasons text[] := '{}';
  v_id uuid;
begin
  if private.user_role() is distinct from 'guard' then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  select s.* into v_site
  from public.sites s
  join public.guard_sites gs on gs.site_id = s.id
  where s.id = p_site_id and s.active and gs.guard_id = v_uid and gs.active;
  if not found then
    raise exception 'guarda no asignado a este sitio' using errcode = '42501';
  end if;
  if p_kind not in ('shift_start','random_check')
     or p_method not in ('face','password_fallback','face_rejected') then
    raise exception 'parámetros inválidos' using errcode = '22023';
  end if;
  if p_device_id is not null and not exists (
       select 1 from public.devices d where d.id = p_device_id and d.site_id = p_site_id and d.active) then
    raise exception 'teléfono no vinculado a este sitio' using errcode = '42501';
  end if;
  if p_photo_path is not null and p_photo_path not like (v_site.company_id::text || '/%') then
    raise exception 'ruta de foto inválida' using errcode = '22023';
  end if;

  if p_lat is null or p_lng is null then
    v_within := false;
    v_reasons := v_reasons || 'sin GPS';
  else
    v_dist := 6371000 * 2 * asin(least(1, sqrt(
        power(sin(radians(p_lat - v_site.lat) / 2), 2)
        + cos(radians(v_site.lat)) * cos(radians(p_lat)) * power(sin(radians(p_lng - v_site.lng) / 2), 2))));
    v_within := v_dist <= v_site.radius_m;
    if not v_within then
      v_reasons := v_reasons || ('fuera del perímetro (' || round(v_dist)::text || ' m)');
    end if;
  end if;

  if p_method = 'password_fallback' then
    v_reasons := v_reasons || ('sin cara: ' || coalesce(nullif(trim(p_fallback_reason), ''), 'sin motivo'));
  elsif p_method = 'face_rejected' then
    v_reasons := v_reasons || 'cara no reconocida (posible intruso)';
  elsif p_matched_guard_id is distinct from v_uid then
    v_reasons := v_reasons || 'la cara no coincide con el usuario';
  end if;

  insert into public.shift_verifications
    (company_id, guard_id, site_id, device_id, kind, method, face_score, matched_guard_id,
     lat, lng, distance_m, within_perimeter, flagged, flag_reason, photo_path)
  values
    (v_site.company_id, v_uid, p_site_id, p_device_id, p_kind, p_method, p_face_score, p_matched_guard_id,
     p_lat, p_lng, v_dist::real, v_within, cardinality(v_reasons) > 0, nullif(array_to_string(v_reasons, '; '), ''), p_photo_path)
  returning id into v_id;

  return query select v_id, v_within, cardinality(v_reasons) > 0, nullif(array_to_string(v_reasons, '; '), '');
end $$;

revoke execute on function public.get_site_face_templates(uuid) from public, anon;
revoke execute on function public.register_verification(uuid, uuid, text, text, real, uuid, double precision, double precision, text, text) from public, anon;
grant execute on function public.get_site_face_templates(uuid) to authenticated;
grant execute on function public.register_verification(uuid, uuid, text, text, real, uuid, double precision, double precision, text, text) to authenticated;
