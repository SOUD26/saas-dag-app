-- Corrección: cuando el súper admin crea una empresa desde la app, la plantilla de documentos
-- perdía sus claves (el trigger vaciaba "key" en todo alta hecha por un usuario de la app).
-- Ahora la plantilla marca que está sembrando y el trigger respeta sus claves.

create or replace function private.seed_document_types(p_company uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('app.seeding_types', 'on', true);
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
  perform set_config('app.seeding_types', 'off', true);
end $$;

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
  if tg_op = 'INSERT' and (select auth.uid()) is not null
     and coalesce(current_setting('app.seeding_types', true), '') <> 'on' then
    new.key := null;  -- las claves base las pone solo la plantilla
  end if;
  return new;
end $$;
