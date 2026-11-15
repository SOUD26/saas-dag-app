-- Módulo 2 · Ficha al contratar.
-- * La ficha dice si la persona porta arma, conduce moto o conduce vehículo: eso vuelve obligatoria
--   la licencia correspondiente (si falta o vence, sale alerta).
-- * Licencia de moto (tipo M) y de vehículo (A, B o C) por separado: en Guatemala son tarjetas distintas.
-- * Foto de perfil obligatoria para guardas y supervisores (si falta, sale alerta).
-- * save_staff_file(): guarda teléfono + ficha + documentos en un solo paso (todo o nada). Corre con
--   los permisos de quien llama (security invoker): no da acceso extra, las reglas de RLS siguen mandando.
-- * staff_precheck(): revisa DPI y código de empleado antes de crear la cuenta.

alter table public.staff_records
  add column if not exists carries_weapon boolean not null default false,
  add column if not exists drives_motorcycle boolean not null default false,
  add column if not exists drives_vehicle boolean not null default false;

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
    (p_company, 'driver_license',        'Licencia de vehículo (tipo A, B o C)',    'staff',   '{supervisor,guard}',               true,  false, 70),
    (p_company, 'motorcycle_license',    'Licencia de moto (tipo M)',               'staff',   '{supervisor,guard}',               true,  false, 75),
    (p_company, 'digessp_license',       'Licencia de operación (DIGESSP)',         'company', '{}',                               true,  true,  10),
    (p_company, 'legal_rep_appointment', 'Nombramiento del representante legal',    'company', '{}',                               true,  false, 20),
    (p_company, 'commerce_patent',       'Patente de comercio',                     'company', '{}',                               false, false, 30),
    (p_company, 'rtu',                   'RTU (SAT)',                               'company', '{}',                               false, false, 40),
    (p_company, 'digecam_authorization', 'Autorización de armas de la empresa (DIGECAM)', 'company', '{}',                         true,  false, 50),
    (p_company, 'insurance',             'Póliza de seguro o fianza',               'company', '{}',                               true,  false, 60),
    (p_company, 'service_contract',      'Contrato de servicio',                    'client',  '{}',                               false, false, 10)
  on conflict do nothing;
$$;

-- Empresas existentes: renombrar la licencia de conducir (si conserva el nombre base) y agregar la de moto.
update public.document_types
   set name = 'Licencia de vehículo (tipo A, B o C)', roles = '{supervisor,guard}'
 where key = 'driver_license' and name = 'Licencia de conducir';
select private.seed_document_types(id) from public.companies;

-- Alertas: + licencias que exige lo que hace la persona + foto faltante.
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
    select p.id, p.full_name, p.role, p.avatar_path,
           coalesce(sr.carries_weapon, false) as weapon,
           coalesce(sr.drives_motorcycle, false) as moto,
           coalesce(sr.drives_vehicle, false) as vehicle
    from public.profiles p
    left join public.staff_records sr on sr.profile_id = p.id
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
    -- obligatorios que faltan: los del rol y los que exige lo que hace (arma, moto, vehículo)
    select pe.id, pe.full_name, pe.role, t.id, t.key, t.name, null::uuid, null::date
    from people pe
    join public.document_types t on t.company_id = p_company and t.applies_to = 'staff' and t.active
         and ((t.required and pe.role = any (t.roles))
              or (t.key = 'weapon_license' and pe.weapon)
              or (t.key = 'motorcycle_license' and pe.moto)
              or (t.key = 'driver_license' and pe.vehicle))
    where not exists (select 1 from staff_cur sc where sc.profile_id = pe.id and sc.type_id = t.id)
    union all
    -- foto de perfil: obligatoria para guardas y supervisores (para reconocerse en el sitio)
    select pe.id, pe.full_name, pe.role, null::uuid, 'avatar'::text, 'Foto de perfil'::text, null::uuid, null::date
    from people pe
    where pe.role in ('guard', 'supervisor') and pe.avatar_path is null
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

-- Guardar ficha completa en un paso. p_record y p_documents son opcionales (cliente/usuario: solo teléfono).
-- p_documents: [{ "type_key": "weapon_license", "number": "...", "issued_on": "2026-01-01", "expires_on": "2027-01-01", "id": null }]
--   con id  -> corrige ese documento;  sin id -> agrega uno nuevo (renovación).
create or replace function public.save_staff_file(
  p_profile uuid,
  p_phone text default null,
  p_record jsonb default null,
  p_documents jsonb default null)
returns void
language plpgsql security invoker set search_path = '' as $$
declare
  v_n integer;
  v_doc jsonb;
  v_type uuid;
begin
  update public.profiles set phone = nullif(btrim(coalesce(p_phone, '')), '') where id = p_profile;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception 'no autorizado para editar a esta persona' using errcode = '42501';
  end if;

  if p_record is not null then
    insert into public.staff_records as s (
      profile_id, company_id, employee_code, first_names, last_names, dpi, birth_date,
      address, department, municipality,
      emergency_contact_name, emergency_contact_phone, emergency_contact_relation,
      hire_date, termination_date, carries_weapon, drives_motorcycle, drives_vehicle)
    values (
      p_profile, (select p.company_id from public.profiles p where p.id = p_profile),
      p_record ->> 'employee_code', p_record ->> 'first_names', p_record ->> 'last_names', p_record ->> 'dpi',
      nullif(p_record ->> 'birth_date', '')::date,
      p_record ->> 'address', p_record ->> 'department', p_record ->> 'municipality',
      p_record ->> 'emergency_contact_name', p_record ->> 'emergency_contact_phone', p_record ->> 'emergency_contact_relation',
      nullif(p_record ->> 'hire_date', '')::date, nullif(p_record ->> 'termination_date', '')::date,
      coalesce((p_record ->> 'carries_weapon')::boolean, false),
      coalesce((p_record ->> 'drives_motorcycle')::boolean, false),
      coalesce((p_record ->> 'drives_vehicle')::boolean, false))
    on conflict (profile_id) do update set
      first_names = excluded.first_names,
      last_names = excluded.last_names,
      employee_code = case when p_record ? 'employee_code' then excluded.employee_code else s.employee_code end,
      dpi = case when p_record ? 'dpi' then excluded.dpi else s.dpi end,
      birth_date = case when p_record ? 'birth_date' then excluded.birth_date else s.birth_date end,
      address = case when p_record ? 'address' then excluded.address else s.address end,
      department = case when p_record ? 'department' then excluded.department else s.department end,
      municipality = case when p_record ? 'municipality' then excluded.municipality else s.municipality end,
      emergency_contact_name = case when p_record ? 'emergency_contact_name' then excluded.emergency_contact_name else s.emergency_contact_name end,
      emergency_contact_phone = case when p_record ? 'emergency_contact_phone' then excluded.emergency_contact_phone else s.emergency_contact_phone end,
      emergency_contact_relation = case when p_record ? 'emergency_contact_relation' then excluded.emergency_contact_relation else s.emergency_contact_relation end,
      hire_date = case when p_record ? 'hire_date' then excluded.hire_date else s.hire_date end,
      termination_date = case when p_record ? 'termination_date' then excluded.termination_date else s.termination_date end,
      carries_weapon = case when p_record ? 'carries_weapon' then excluded.carries_weapon else s.carries_weapon end,
      drives_motorcycle = case when p_record ? 'drives_motorcycle' then excluded.drives_motorcycle else s.drives_motorcycle end,
      drives_vehicle = case when p_record ? 'drives_vehicle' then excluded.drives_vehicle else s.drives_vehicle end;
  end if;

  if p_documents is not null then
    for v_doc in select value from jsonb_array_elements(p_documents) loop
      if nullif(v_doc ->> 'id', '') is not null then
        update public.documents
           set number = v_doc ->> 'number',
               issued_on = nullif(v_doc ->> 'issued_on', '')::date,
               expires_on = nullif(v_doc ->> 'expires_on', '')::date
         where id = (v_doc ->> 'id')::uuid and profile_id = p_profile;
        get diagnostics v_n = row_count;
        if v_n = 0 then
          raise exception 'documento no encontrado' using errcode = '22023';
        end if;
      elsif coalesce(nullif(v_doc ->> 'number', ''), nullif(v_doc ->> 'issued_on', ''), nullif(v_doc ->> 'expires_on', '')) is not null then
        v_type := null;
        select t.id into v_type
          from public.document_types t
          join public.profiles p on p.company_id = t.company_id
         where p.id = p_profile and t.applies_to = 'staff' and t.key = v_doc ->> 'type_key';
        if v_type is null then
          raise exception 'tipo de documento desconocido: %', v_doc ->> 'type_key' using errcode = '22023';
        end if;
        insert into public.documents (type_id, profile_id, number, issued_on, expires_on)
        values (v_type, p_profile, v_doc ->> 'number',
                nullif(v_doc ->> 'issued_on', '')::date, nullif(v_doc ->> 'expires_on', '')::date);
      end if;
    end loop;
  end if;
end $$;

revoke execute on function public.save_staff_file(uuid, text, jsonb, jsonb) from public, anon;
grant execute on function public.save_staff_file(uuid, text, jsonb, jsonb) to authenticated;

-- Revisión previa al crear la cuenta: DPI y código de empleado repetidos en la empresa.
-- Devuelve el mensaje del problema o null si todo está bien. Corre con los permisos de quien llama.
create or replace function public.staff_precheck(
  p_company uuid,
  p_dpi text,
  p_employee_code text default null,
  p_profile uuid default null)
returns text
language plpgsql stable security invoker set search_path = '' as $$
declare
  v_dpi text := nullif(regexp_replace(coalesce(p_dpi, ''), '[^0-9]', '', 'g'), '');
  v_code text := nullif(btrim(coalesce(p_employee_code, '')), '');
  v_name text;
begin
  if v_dpi is not null and v_dpi !~ '^[0-9]{13}$' then
    return 'El DPI debe tener 13 dígitos.';
  end if;
  if v_dpi is not null then
    select p.full_name into v_name
      from public.staff_records s join public.profiles p on p.id = s.profile_id
     where s.company_id = p_company and s.dpi = v_dpi and s.profile_id is distinct from p_profile
     limit 1;
    if found then
      return format('Ese DPI ya está registrado a nombre de %s.', v_name);
    end if;
  end if;
  if v_code is not null then
    select p.full_name into v_name
      from public.staff_records s join public.profiles p on p.id = s.profile_id
     where s.company_id = p_company and lower(s.employee_code) = lower(v_code) and s.profile_id is distinct from p_profile
     limit 1;
    if found then
      return format('El código %s ya lo tiene %s.', v_code, v_name);
    end if;
  end if;
  return null;
end $$;

revoke execute on function public.staff_precheck(uuid, text, text, uuid) from public, anon;
grant execute on function public.staff_precheck(uuid, text, text, uuid) to authenticated;
