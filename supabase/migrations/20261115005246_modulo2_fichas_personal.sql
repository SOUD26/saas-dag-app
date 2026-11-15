-- Módulo 2 · Ficha de personal (administradores, supervisores y guardas), teléfono y foto en el perfil.
-- También cierra un hueco: el admin de empresa ya no puede cambiar roles ni tocar la cuenta de otros administradores.

-- ---------------------------------------------------------------------------
-- Quién puede qué sobre una persona
-- ---------------------------------------------------------------------------
-- Editar datos de la persona (perfil, ficha, documentos, foto):
--   súper admin: a todos menos a otros súper admin (a sí mismo sí);
--   admin de empresa: a cualquiera de su empresa, menos súper admin.
-- (Activar/desactivar a otro administrador sigue siendo solo del súper admin: lo cuida el trigger de profiles.)
create or replace function private.can_edit_person(p_profile uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select case
      when private.user_role() = 'super_admin' then t.role <> 'super_admin' or t.id = (select auth.uid())
      when private.user_role() = 'company_admin' then t.company_id = private.user_company() and t.role <> 'super_admin'
      else false end
    from public.profiles t where t.id = p_profile), false)
$$;

-- Ver datos de RR. HH. (ficha y documentos): la propia persona, el admin de su empresa y el súper admin.
create or replace function private.can_view_hr(p_profile uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select (t.id = (select auth.uid()) and private.user_role() is not null)
        or private.is_admin_of(t.company_id)
    from public.profiles t where t.id = p_profile), false)
$$;

-- Ver a la persona (perfil y foto): mismo criterio que profiles_select (+ el supervisor ve a sus guardas).
create or replace function private.can_view_person(p_profile uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select (t.id = (select auth.uid()) and private.user_role() is not null)
        or private.is_admin_of(t.company_id)
        or private.supervises_guard(t.id)
    from public.profiles t where t.id = p_profile), false)
$$;

-- ---------------------------------------------------------------------------
-- Perfil: teléfono y foto. El rol y el cliente ya no se cambian desde la app.
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists phone text,
  add column if not exists avatar_path text;

alter table public.profiles
  add constraint profiles_phone_format check (phone is null or phone ~ '^\+?[0-9]{8,15}$'),
  add constraint profiles_avatar_path check (avatar_path is null or avatar_path like (id::text || '/%'));

revoke update (role, client_id) on public.profiles from authenticated;
grant update (phone, avatar_path) on public.profiles to authenticated;

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (private.can_edit_person(id))
  with check (private.can_edit_person(id));

create or replace function private.profiles_before_update() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.full_name := private.norm_text(new.full_name);
  if new.full_name is null then
    raise exception 'nombre requerido' using errcode = '22023';
  end if;
  new.phone := private.norm_phone(new.phone);
  if (select auth.uid()) is not null then
    if new.active is distinct from old.active then
      if new.id = (select auth.uid()) then
        raise exception 'no puedes desactivar tu propia cuenta' using errcode = '42501';
      end if;
      if old.role = 'company_admin' and private.user_role() is distinct from 'super_admin' then
        raise exception 'solo el súper admin activa o desactiva administradores' using errcode = '42501';
      end if;
    end if;
    if new.full_name is distinct from old.full_name
       and coalesce(current_setting('app.staff_name_sync', true), '') <> 'on'
       and exists (select 1 from public.staff_records s where s.profile_id = new.id) then
      raise exception 'el nombre de esta persona se cambia en su ficha (nombres y apellidos)' using errcode = '22023';
    end if;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Ficha de personal (expediente): solo administradores, supervisores y guardas.
-- ---------------------------------------------------------------------------
create table if not exists public.staff_records (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  company_id uuid not null references public.companies(id),
  employee_code text,
  first_names text not null,
  last_names text not null,
  dpi text,
  birth_date date,
  address text,
  department text,
  municipality text,
  emergency_contact_name text,
  emergency_contact_phone text,
  emergency_contact_relation text,
  hire_date date,
  termination_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid() references public.profiles(id) on delete set null,
  constraint staff_dpi_format check (dpi is null or dpi ~ '^[0-9]{13}$'),
  constraint staff_birth_date check (birth_date is null or birth_date >= date '1900-01-01'),
  constraint staff_emergency_phone check (emergency_contact_phone is null or emergency_contact_phone ~ '^\+?[0-9]{8,15}$'),
  constraint staff_dates check (termination_date is null or hire_date is null or termination_date >= hire_date)
);

create unique index if not exists staff_records_code_key
  on public.staff_records (company_id, lower(employee_code)) where employee_code is not null;
create unique index if not exists staff_records_dpi_key
  on public.staff_records (company_id, dpi) where dpi is not null;

-- La trigger de profiles necesita la tabla de fichas: se crea después de ella.
drop trigger if exists trg_profiles_before_update on public.profiles;
create trigger trg_profiles_before_update before update on public.profiles
  for each row execute function private.profiles_before_update();

create or replace function private.staff_records_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  t public.profiles%rowtype;
begin
  select * into t from public.profiles where id = new.profile_id;
  if not found then
    raise exception 'persona no encontrada' using errcode = '22023';
  end if;
  if t.role not in ('company_admin', 'supervisor', 'guard') then
    raise exception 'la ficha de personal es solo para administradores, supervisores y guardas' using errcode = '22023';
  end if;
  new.company_id := t.company_id;
  new.employee_code := private.norm_text(new.employee_code);
  new.first_names := private.norm_text(new.first_names);
  new.last_names := private.norm_text(new.last_names);
  if new.first_names is null or new.last_names is null then
    raise exception 'nombres y apellidos son obligatorios' using errcode = '22023';
  end if;
  new.dpi := private.norm_digits(new.dpi);
  new.address := private.norm_text(new.address);
  new.department := private.norm_text(new.department);
  new.municipality := private.norm_text(new.municipality);
  new.emergency_contact_name := private.norm_text(new.emergency_contact_name);
  new.emergency_contact_phone := private.norm_phone(new.emergency_contact_phone);
  new.emergency_contact_relation := private.norm_text(new.emergency_contact_relation);
  if new.birth_date is not null
     and (tg_op = 'INSERT' or new.birth_date is distinct from old.birth_date)
     and new.birth_date > (current_date - interval '18 years')::date then
    raise exception 'la persona debe ser mayor de edad: revise la fecha de nacimiento' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' then
    if new.profile_id is distinct from old.profile_id then
      raise exception 'no se puede cambiar la persona de una ficha' using errcode = '22023';
    end if;
    new.created_at := old.created_at;
    new.updated_at := now();
    new.updated_by := (select auth.uid());
  end if;
  return new;
end $$;

drop trigger if exists trg_staff_records_before_write on public.staff_records;
create trigger trg_staff_records_before_write before insert or update on public.staff_records
  for each row execute function private.staff_records_before_write();

-- El nombre que se muestra en toda la app sale de la ficha: nombres + apellidos.
create or replace function private.staff_records_sync_name() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('app.staff_name_sync', 'on', true);
  update public.profiles
     set full_name = new.first_names || ' ' || new.last_names
   where id = new.profile_id
     and full_name is distinct from (new.first_names || ' ' || new.last_names);
  perform set_config('app.staff_name_sync', 'off', true);
  return null;
end $$;

drop trigger if exists trg_staff_records_sync_name on public.staff_records;
create trigger trg_staff_records_sync_name after insert or update of first_names, last_names on public.staff_records
  for each row execute function private.staff_records_sync_name();

alter table public.staff_records enable row level security;

drop policy if exists staff_select on public.staff_records;
create policy staff_select on public.staff_records for select to authenticated
  using (private.can_view_hr(profile_id));

drop policy if exists staff_insert on public.staff_records;
create policy staff_insert on public.staff_records for insert to authenticated
  with check (private.can_edit_person(profile_id));

drop policy if exists staff_update on public.staff_records;
create policy staff_update on public.staff_records for update to authenticated
  using (private.can_edit_person(profile_id))
  with check (private.can_edit_person(profile_id));

-- Una ficha no se borra (se conserva el expediente); se va solo si se borra la persona.
revoke all on public.staff_records from anon;
revoke delete, truncate, trigger, references on public.staff_records from authenticated;

-- ---------------------------------------------------------------------------
-- Contacto de emergencia: también para el supervisor de ese guarda (sin ver DPI ni dirección).
-- ---------------------------------------------------------------------------
create or replace function public.staff_emergency_contact(p_profile uuid)
returns table (contact_name text, contact_phone text, contact_relation text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (private.can_view_hr(p_profile) or private.supervises_guard(p_profile)) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  return query
    select s.emergency_contact_name, s.emergency_contact_phone, s.emergency_contact_relation
    from public.staff_records s where s.profile_id = p_profile;
end $$;

revoke execute on function public.staff_emergency_contact(uuid) from public, anon;
grant execute on function public.staff_emergency_contact(uuid) to authenticated;
