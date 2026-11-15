-- Módulo 2 · Fichas de empresa (cliente de SaaS-DAG) y de cliente (condominio/ofibodega).
-- Incluye normalizadores comunes, suscripción de cada empresa (solo súper admin) e higiene de permisos.

-- ---------------------------------------------------------------------------
-- Normalizadores (funciones puras): quitan espacios, guiones, mayúsculas, etc.
-- ---------------------------------------------------------------------------
create or replace function private.norm_text(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(btrim(regexp_replace(coalesce(p, ''), '[[:space:]]+', ' ', 'g')), '')
$$;

create or replace function private.norm_digits(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g'), '')
$$;

-- NIT de Guatemala: solo dígitos y K (dígito verificador). "CF" queda vacío.
create or replace function private.norm_nit(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(upper(regexp_replace(coalesce(p, ''), '[^0-9Kk]', '', 'g')), '')
$$;

-- Teléfono: solo dígitos; conserva el + inicial si lo trae.
create or replace function private.norm_phone(p text) returns text
language sql immutable set search_path = '' as $$
  select case
    when private.norm_digits(p) is null then null
    when btrim(p) like '+%' then '+' || private.norm_digits(p)
    else private.norm_digits(p) end
$$;

create or replace function private.norm_email(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(lower(btrim(coalesce(p, ''))), '')
$$;

-- Convierte texto a uuid sin lanzar error (para rutas de archivos).
create or replace function private.try_uuid(p text) returns uuid
language plpgsql immutable set search_path = '' as $$
begin
  return p::uuid;
exception when others then
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- Empresa de seguridad (la ve y edita el súper admin; el admin de la empresa
-- puede editar solo contacto y logo de la suya).
-- ---------------------------------------------------------------------------
alter table public.companies
  add column if not exists legal_name text,
  add column if not exists nit text,
  add column if not exists legal_rep_name text,
  add column if not exists phone text,
  add column if not exists email text,
  add column if not exists address text,
  add column if not exists department text,
  add column if not exists municipality text,
  add column if not exists logo_path text,
  add column if not exists updated_at timestamptz not null default now();

alter table public.companies
  add constraint companies_nit_format check (nit is null or nit ~ '^[0-9]{1,12}[0-9K]$'),
  add constraint companies_phone_format check (phone is null or phone ~ '^\+?[0-9]{8,15}$'),
  add constraint companies_email_format check (email is null or email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  add constraint companies_logo_path check (logo_path is null or logo_path like (id::text || '/%'));

create unique index if not exists companies_nit_key on public.companies (nit) where nit is not null;

create or replace function private.companies_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.name := private.norm_text(new.name);
  if new.name is null then
    raise exception 'nombre de la empresa requerido' using errcode = '22023';
  end if;
  new.legal_name := private.norm_text(new.legal_name);
  new.nit := private.norm_nit(new.nit);
  new.legal_rep_name := private.norm_text(new.legal_rep_name);
  new.phone := private.norm_phone(new.phone);
  new.email := private.norm_email(new.email);
  new.address := private.norm_text(new.address);
  new.department := private.norm_text(new.department);
  new.municipality := private.norm_text(new.municipality);
  if tg_op = 'UPDATE' then
    new.updated_at := now();
    -- Solo se aplica a usuarios de la app; el mantenimiento por SQL (sin usuario) queda libre.
    if (select auth.uid()) is not null then
      if new.code is distinct from old.code then
        raise exception 'el código de empresa no se puede cambiar: lo usan los inicios de sesión de los guardas'
          using errcode = '42501';
      end if;
      if private.user_role() is distinct from 'super_admin' and (
           new.name is distinct from old.name
           or new.legal_name is distinct from old.legal_name
           or new.nit is distinct from old.nit
           or new.legal_rep_name is distinct from old.legal_rep_name
           or new.active is distinct from old.active
           or new.created_at is distinct from old.created_at) then
        raise exception 'solo el súper admin cambia nombre, razón social, NIT, representante legal o estado de la empresa'
          using errcode = '42501';
      end if;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_companies_before_write on public.companies;
create trigger trg_companies_before_write before insert or update on public.companies
  for each row execute function private.companies_before_write();

-- El admin de la empresa puede actualizar la suya (el trigger limita qué columnas).
drop policy if exists companies_update_admin on public.companies;
create policy companies_update_admin on public.companies for update to authenticated
  using (private.user_role() = 'company_admin' and id = private.user_company())
  with check (private.user_role() = 'company_admin' and id = private.user_company());

-- ---------------------------------------------------------------------------
-- Suscripción de cada empresa a SaaS-DAG: solo el súper admin (Isaac).
-- "status" es informativo; lo que corta el acceso es companies.active = false.
-- ---------------------------------------------------------------------------
create table if not exists public.company_subscriptions (
  company_id uuid primary key references public.companies(id) on delete cascade,
  status text not null default 'trial' check (status in ('trial', 'active', 'suspended', 'cancelled')),
  plan text,
  monthly_fee numeric(12,2) check (monthly_fee is null or monthly_fee >= 0),
  currency text not null default 'GTQ' check (currency in ('GTQ', 'USD')),
  billing_day smallint check (billing_day between 1 and 28),
  started_on date,
  trial_ends_on date,
  notes text,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references public.profiles(id) on delete set null
);

alter table public.company_subscriptions enable row level security;
drop policy if exists subscriptions_super_admin on public.company_subscriptions;
create policy subscriptions_super_admin on public.company_subscriptions for all to authenticated
  using (private.user_role() = 'super_admin')
  with check (private.user_role() = 'super_admin');

create or replace function private.touch_updated() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.updated_at := now();
  new.updated_by := (select auth.uid());
  return new;
end $$;

drop trigger if exists trg_subscriptions_touch on public.company_subscriptions;
create trigger trg_subscriptions_touch before update on public.company_subscriptions
  for each row execute function private.touch_updated();

-- Cada empresa nueva nace con su suscripción en "prueba".
create or replace function private.companies_after_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.company_subscriptions (company_id) values (new.id) on conflict do nothing;
  return null;
end $$;

drop trigger if exists trg_companies_after_insert on public.companies;
create trigger trg_companies_after_insert after insert on public.companies
  for each row execute function private.companies_after_insert();

insert into public.company_subscriptions (company_id)
select id from public.companies on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Cliente de la empresa (condominio, residencial, ofibodega...).
-- ---------------------------------------------------------------------------
alter table public.clients
  add column if not exists client_type text,
  add column if not exists legal_name text,
  add column if not exists nit text,
  add column if not exists address text,
  add column if not exists department text,
  add column if not exists municipality text,
  add column if not exists contact_name text,
  add column if not exists contact_role text,
  add column if not exists contact_phone text,
  add column if not exists contact_email text,
  add column if not exists contract_start date,
  add column if not exists contract_end date,
  add column if not exists updated_at timestamptz not null default now();

alter table public.clients
  add constraint clients_type_check check (client_type is null or client_type in
    ('condominium', 'residential', 'office_warehouse', 'office', 'retail', 'industrial', 'other')),
  add constraint clients_nit_format check (nit is null or nit ~ '^[0-9]{1,12}[0-9K]$'),
  add constraint clients_phone_format check (contact_phone is null or contact_phone ~ '^\+?[0-9]{8,15}$'),
  add constraint clients_email_format check (contact_email is null or contact_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  add constraint clients_contract_dates check (contract_end is null or contract_start is null or contract_end >= contract_start);

create or replace function private.clients_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.name := private.norm_text(new.name);
  if new.name is null then
    raise exception 'nombre del cliente requerido' using errcode = '22023';
  end if;
  new.legal_name := private.norm_text(new.legal_name);
  new.nit := private.norm_nit(new.nit);
  new.address := private.norm_text(new.address);
  new.department := private.norm_text(new.department);
  new.municipality := private.norm_text(new.municipality);
  new.contact_name := private.norm_text(new.contact_name);
  new.contact_role := private.norm_text(new.contact_role);
  new.contact_phone := private.norm_phone(new.contact_phone);
  new.contact_email := private.norm_email(new.contact_email);
  if tg_op = 'UPDATE' then
    new.updated_at := now();
    if new.company_id is distinct from old.company_id and (select auth.uid()) is not null then
      raise exception 'un cliente no se puede pasar a otra empresa' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_clients_before_write on public.clients;
create trigger trg_clients_before_write before insert or update on public.clients
  for each row execute function private.clients_before_write();

-- ---------------------------------------------------------------------------
-- Higiene: nadie de la app necesita TRUNCATE/TRIGGER/REFERENCES (TRUNCATE salta RLS).
-- ---------------------------------------------------------------------------
revoke truncate, trigger, references on all tables in schema public from authenticated;
revoke all on public.company_subscriptions from anon;
