-- Pruebas de permisos y aislamiento de las fichas del módulo 2 (empresa, cliente, personal, documentos, archivos, bitácora).
-- Cómo correrlas: pegar en el editor SQL de Supabase (o execute_sql). Usan los datos demo ("Seguridad Demo", código C2193E).
-- Todo se deshace al final: el bloque termina con una excepción que trae el informe ("RESULTADOS: ...").
-- Cada línea dice qué se esperaba. Los conteos de "alertas" dependen de cuántas personas haya en Demo.
do $$
declare
  c_company uuid := (select id from public.companies where code = 'C2193E');
  c_client uuid := (select id from public.clients where name = 'Condominio Demo' and company_id = (select id from public.companies where code = 'C2193E'));
  u_super uuid := (select id from public.profiles where role = 'super_admin' order by created_at limit 1);
  u_admin uuid := (select id from public.profiles where email = 'admin@dag.test');
  u_admin2 uuid := gen_random_uuid();      -- segundo admin de Demo (se crea en la preparación)
  u_sup uuid := (select id from public.profiles where email = 'supervisor@dag.test');
  u_guard uuid := (select id from public.profiles where username = 'guarda' and role = 'guard' limit 1);
  u_guard_free uuid := gen_random_uuid();  -- guarda sin sitio (se crea en la preparación)
  u_guard2 uuid := (select id from public.profiles where username = 'cmendez' limit 1);
  u_client uuid := (select id from public.profiles where email = 'cliente@dag.test');
  u_res uuid := (select id from public.profiles where email = 'usuario@dag.test');
  b_company uuid := gen_random_uuid();
  b_admin uuid := gen_random_uuid();
  b_guard uuid := gen_random_uuid();
  t_dpi uuid; t_weapon uuid; t_contract uuid; tb_dpi uuid;
  d_id uuid;
  v_max bigint;
  r text := '';
  n int; m int;
  v text;
begin
  -- ===== Preparación (como dueño de la base) =====
  select coalesce(max(id), 0) into v_max from public.audit_log;
  select count(*) into n from storage.buckets where id in ('avatars', 'logos', 'documents') and not public;
  r := r || format('P0 buckets privados=%s (esperado 3); ', n);
  insert into public.companies (id, name) values (b_company, 'Empresa Prueba B');
  select count(*) into n from public.document_types where company_id = b_company;
  select count(*) into m from public.company_subscriptions where company_id = b_company;
  r := r || format('P1 empresa nueva: tipos=%s (esperado 14), suscripción=%s; ', n, m);
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (b_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'adminb@prueba.invalid', '', now(), now(), now(), '{}', '{}'),
         (b_guard, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'guardb@prueba.invalid', '', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, company_id, role, full_name, email) values (b_admin, b_company, 'company_admin', 'Admin B', 'adminb@prueba.invalid');
  insert into public.profiles (id, company_id, role, full_name, username) values (b_guard, b_company, 'guard', 'Guarda B', 'guardab');
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (u_admin2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin2@prueba.invalid', '', now(), now(), now(), '{}', '{}'),
         (u_guard_free, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'libre@prueba.invalid', '', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, company_id, role, full_name, email) values (u_admin2, c_company, 'company_admin', 'Admin Dos', 'admin2@prueba.invalid');
  insert into public.profiles (id, company_id, role, full_name, username) values (u_guard_free, c_company, 'guard', 'Guarda Libre', 'libre');
  insert into public.staff_records (profile_id, company_id, first_names, last_names, dpi, emergency_contact_name, emergency_contact_phone)
    values (b_guard, b_company, 'Pedro', 'Be', '9999999999999', 'Mamá B', '55551111');
  select id into t_dpi from public.document_types where company_id = c_company and key = 'dpi';
  select id into t_weapon from public.document_types where company_id = c_company and key = 'weapon_license';
  select id into t_contract from public.document_types where company_id = c_company and key = 'service_contract';
  select id into tb_dpi from public.document_types where company_id = b_company and key = 'dpi';
  insert into public.documents (type_id, profile_id, number, expires_on) values (tb_dpi, b_guard, '9999999999999', current_date + 5);

  -- ===== Admin de empresa (Admin Demo) =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  begin
    insert into public.staff_records (profile_id, company_id, employee_code, first_names, last_names, dpi, birth_date,
                                      emergency_contact_name, emergency_contact_phone, emergency_contact_relation)
    values (u_guard, c_company, 'G-001', '  Juan   Carlos ', 'Pérez López', '2345 67890 0101', '1990-05-01', 'María Pérez', '5555-1234', 'madre');
    select full_name into v from public.profiles where id = u_guard;
    r := r || format('A1 admin crea ficha; nombre en perfil="%s"; ', v);
  exception when others then r := r || 'A1 FALLÓ ' || sqlerrm || '; '; end;

  begin
    insert into public.staff_records (profile_id, company_id, first_names, last_names) values (b_admin, b_company, 'X', 'Y');
    r := r || 'A2 FALLA: creó ficha en otra empresa; ';
  exception when others then r := r || 'A2 ok bloqueado; '; end;

  select count(*) into n from public.staff_records where company_id = b_company;
  r := r || format('A3 fichas de otra empresa visibles=%s (esperado 0); ', n);

  begin
    update public.profiles set active = false where id = u_admin2;
    get diagnostics n = row_count;
    r := r || format('A4 FALLA: desactivó a otro admin (filas=%s); ', n);
  exception when others then r := r || 'A4 ok bloqueado (' || sqlerrm || '); '; end;

  begin
    update public.profiles set active = false where id = u_admin;
    r := r || 'A5 FALLA: se desactivó a sí mismo; ';
  exception when others then r := r || 'A5 ok bloqueado; '; end;

  begin
    update public.profiles set role = 'company_admin' where id = u_guard;
    r := r || 'A6 FALLA: cambió un rol; ';
  exception when others then r := r || 'A6 ok bloqueado (' || sqlstate || '); '; end;

  begin
    update public.profiles set full_name = 'Otro Nombre' where id = u_guard;
    r := r || 'A7 FALLA: cambió nombre por fuera de la ficha; ';
  exception when others then r := r || 'A7 ok bloqueado; '; end;

  begin
    update public.profiles set phone = '+502 5555-0000' where id = u_guard;
    select phone into v from public.profiles where id = u_guard;
    r := r || format('A8 teléfono guardado como %s; ', v);
  exception when others then r := r || 'A8 FALLÓ ' || sqlerrm || '; '; end;

  begin
    insert into public.staff_records (profile_id, company_id, first_names, last_names) values (u_client, c_company, 'Cli', 'Ente');
    r := r || 'A9 FALLA: ficha de personal para un cliente; ';
  exception when others then r := r || 'A9 ok bloqueado; '; end;

  begin
    insert into public.staff_records (profile_id, company_id, first_names, last_names, birth_date)
    values (u_guard2, c_company, 'Carlos', 'Méndez', '2015-01-01');
    r := r || 'A10 FALLA: aceptó menor de edad; ';
  exception when others then r := r || 'A10 ok bloqueado; '; end;

  begin
    insert into public.documents (type_id, profile_id, number, expires_on)
    values (t_dpi, u_guard, '2345678900101', current_date + 400) returning id into d_id;
    insert into public.documents (type_id, profile_id, number, issued_on, expires_on)
    values (t_weapon, u_guard, 'LP-123', current_date - 300, current_date + 10);
    r := r || 'A11 documentos creados; ';
  exception when others then r := r || 'A11 FALLÓ ' || sqlerrm || '; '; end;

  begin
    insert into public.documents (type_id, profile_id, number) values (t_weapon, u_guard2, 'LP-999');
    r := r || 'A12 FALLA: licencia sin vencimiento; ';
  exception when others then r := r || 'A12 ok bloqueado; '; end;

  begin
    insert into public.documents (type_id, client_id, number) values (t_contract, c_client, 'CT-1');
    r := r || 'A13 contrato de cliente creado; ';
  exception when others then r := r || 'A13 FALLÓ ' || sqlerrm || '; '; end;

  select string_agg(x, ' ') into v from (
    select owner_kind || '/' || status || '=' || count(*) as x
    from public.document_alerts(c_company, 30) group by owner_kind, status order by 1) s;
  r := r || 'A14 alertas admin: ' || coalesce(v, 'ninguna') || '; ';

  begin
    update public.companies set phone = '2222-3333' where id = c_company;
    get diagnostics n = row_count;
    r := r || format('A15 admin edita teléfono de su empresa (filas=%s); ', n);
  exception when others then r := r || 'A15 FALLÓ ' || sqlerrm || '; '; end;

  begin
    update public.companies set nit = '1234567K' where id = c_company;
    r := r || 'A16 FALLA: admin cambió el NIT; ';
  exception when others then r := r || 'A16 ok bloqueado; '; end;

  select count(*) into n from public.company_subscriptions;
  r := r || format('A17 suscripciones visibles=%s (esperado 0); ', n);

  begin
    insert into storage.objects (bucket_id, name) values ('avatars', u_guard::text || '/foto.jpg');
    r := r || 'A18 sube foto de su guarda; ';
  exception when others then r := r || 'A18 FALLÓ ' || sqlerrm || '; '; end;

  begin
    insert into storage.objects (bucket_id, name) values ('documents', c_company::text || '/' || d_id::text || '/dpi.pdf');
    r := r || 'A19 sube escaneo del DPI; ';
  exception when others then r := r || 'A19 FALLÓ ' || sqlerrm || '; '; end;

  begin
    insert into storage.objects (bucket_id, name) values ('avatars', b_guard::text || '/foto.jpg');
    r := r || 'A20 FALLA: subió foto a otra empresa; ';
  exception when others then r := r || 'A20 ok bloqueado; '; end;

  begin
    update public.shifts set grace_minutes = grace_minutes + 5
     where id = (select s.id from public.shifts s where s.company_id = c_company order by s.starts_at limit 1);
    get diagnostics n = row_count;
    r := r || format('A21 turno editado (filas=%s); ', n);
  exception when others then r := r || 'A21 FALLÓ ' || sqlerrm || '; '; end;
  execute 'reset role';

  -- ===== Supervisor =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.staff_records;
  r := r || format('S1 fichas visibles=%s (esperado 0); ', n);
  select count(*) into n from public.documents;
  r := r || format('S2 documentos visibles=%s (esperado 0); ', n);
  begin
    select contact_phone into v from public.staff_emergency_contact(u_guard);
    r := r || format('S3 contacto de emergencia de su guarda=%s; ', v);
  exception when others then r := r || 'S3 FALLÓ ' || sqlerrm || '; '; end;
  begin
    perform * from public.staff_emergency_contact(u_guard_free);
    r := r || 'S4 FALLA: vio contacto de un guarda que no supervisa; ';
  exception when others then r := r || 'S4 ok bloqueado; '; end;
  select string_agg(x, ' ') into v from (
    select owner_kind || '/' || status || '=' || count(*) as x
    from public.document_alerts(c_company, 30) group by owner_kind, status order by 1) s;
  r := r || 'S5 alertas supervisor: ' || coalesce(v, 'ninguna') || '; ';
  select count(*) into n from storage.objects where bucket_id = 'avatars' and name like u_guard::text || '/%';
  r := r || format('S6 ve foto de su guarda=%s (esperado 1); ', n);
  select count(*) into n from storage.objects where bucket_id = 'documents';
  r := r || format('S7 escaneos visibles=%s (esperado 0); ', n);
  begin
    insert into public.documents (type_id, profile_id, number, expires_on) values (t_dpi, u_guard2, 'X', current_date + 100);
    r := r || 'S8 FALLA: supervisor creó un documento; ';
  exception when others then r := r || 'S8 ok bloqueado; '; end;
  select count(*) into n from public.profiles where id = u_guard and phone is not null;
  r := r || format('S9 ve teléfono de su guarda=%s (esperado 1); ', n);
  execute 'reset role';

  -- ===== Guarda =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_guard, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.staff_records;
  r := r || format('G1 fichas visibles=%s (esperado 1, la suya); ', n);
  select count(*) into n from public.documents;
  r := r || format('G2 documentos visibles=%s (esperado 2, los suyos); ', n);
  select string_agg(x, ' ') into v from (
    select owner_kind || '/' || status || '=' || count(*) as x
    from public.document_alerts(c_company, 30) group by owner_kind, status order by 1) s;
  r := r || 'G3 alertas guarda: ' || coalesce(v, 'ninguna') || '; ';
  begin
    perform * from public.staff_emergency_contact(u_guard2);
    r := r || 'G4 FALLA: vio contacto de otro guarda; ';
  exception when others then r := r || 'G4 ok bloqueado; '; end;
  begin
    update public.staff_records set address = 'x' where profile_id = u_guard;
    get diagnostics n = row_count;
    r := r || format('G5 edita su propia ficha (filas=%s, esperado 0); ', n);
  exception when others then r := r || 'G5 ok bloqueado; '; end;
  execute 'reset role';

  -- ===== Cliente =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_client, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.staff_records;
  r := r || format('C1 fichas visibles=%s (esperado 0); ', n);
  select count(*) into n from public.documents;
  r := r || format('C2 documentos visibles=%s (esperado 1, su contrato); ', n);
  select count(*) into n from public.document_alerts(c_company, 30);
  r := r || format('C3 alertas=%s (esperado 0); ', n);
  select count(*), count(subscription_status) into n, m from public.company_summary;
  r := r || format('C4 resumen de empresas=%s, con suscripción=%s (esperado 1/0); ', n, m);
  select count(*) into n from storage.objects where bucket_id in ('avatars', 'documents');
  r := r || format('C5 fotos/escaneos visibles=%s (esperado 0); ', n);
  execute 'reset role';

  -- ===== Usuario (residente) =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_res, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.documents;
  select count(*) into m from public.staff_records;
  r := r || format('R1 documentos=%s fichas=%s (esperado 0/0); ', n, m);
  execute 'reset role';

  -- ===== Admin de OTRA empresa =====
  perform set_config('request.jwt.claims', json_build_object('sub', b_admin, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.staff_records where company_id = c_company;
  select count(*) into m from public.documents where company_id = c_company;
  r := r || format('B1 ve de Demo: fichas=%s documentos=%s (esperado 0/0); ', n, m);
  begin
    perform * from public.document_alerts(c_company, 30);
    r := r || 'B2 FALLA: vio alertas de Demo; ';
  exception when others then r := r || 'B2 ok bloqueado; '; end;
  begin
    perform * from public.staff_emergency_contact(u_guard);
    r := r || 'B3 FALLA: vio contacto de un guarda de Demo; ';
  exception when others then r := r || 'B3 ok bloqueado; '; end;
  select count(*) into n from storage.objects where bucket_id in ('avatars', 'documents');
  r := r || format('B4 archivos de Demo visibles=%s (esperado 0); ', n);
  begin
    insert into public.documents (type_id, profile_id, number, expires_on) values (t_dpi, b_guard, 'X', current_date + 10);
    r := r || 'B5 FALLA: usó un tipo de documento de otra empresa; ';
  exception when others then r := r || 'B5 ok bloqueado; '; end;
  select count(*) into n from public.document_types where company_id = c_company;
  r := r || format('B6 tipos de Demo visibles=%s (esperado 0); ', n);
  select string_agg(x, ' ') into v from (
    select owner_kind || '/' || status || '=' || count(*) as x
    from public.document_alerts(b_company, 30) group by owner_kind, status order by 1) s;
  r := r || 'B7 alertas de su empresa: ' || coalesce(v, 'ninguna') || '; ';
  execute 'reset role';

  -- ===== Súper admin (Isaac) =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_super, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into n from public.company_subscriptions;
  r := r || format('SA1 suscripciones visibles=%s; ', n);
  begin
    update public.company_subscriptions set monthly_fee = 1500, status = 'active', notes = 'nota interna'
     where company_id = c_company;
    r := r || 'SA2 suscripción editada; ';
  exception when others then r := r || 'SA2 FALLÓ ' || sqlerrm || '; '; end;
  select count(*) into n from public.document_alerts(null, 30);
  r := r || format('SA3 alertas de plataforma=%s (esperado: una por empresa activa sin licencia DIGESSP); ', n);
  begin
    update public.companies set code = 'ZZZZZZ' where id = c_company;
    r := r || 'SA4 FALLA: cambió el código de empresa; ';
  exception when others then r := r || 'SA4 ok bloqueado; '; end;
  begin
    update public.companies set nit = '576-0', legal_name = 'Seguridad Demo, S.A.' where id = c_company;
    select nit into v from public.companies where id = c_company;
    r := r || format('SA5 edita NIT (guardado como %s); ', v);
  exception when others then r := r || 'SA5 FALLÓ ' || sqlerrm || '; '; end;
  select count(*) into n from public.staff_records;
  r := r || format('SA6 fichas visibles=%s (todas); ', n);
  begin
    update public.profiles set active = false where id = u_admin2;
    get diagnostics n = row_count;
    r := r || format('SA7 desactiva a un admin (filas=%s); ', n);
  exception when others then r := r || 'SA7 FALLÓ ' || sqlerrm || '; '; end;
  select count(*), count(subscription_status) into n, m from public.company_summary;
  r := r || format('SA8 resumen de empresas=%s con suscripción=%s; ', n, m);
  execute 'reset role';

  -- ===== Bitácora =====
  select count(*) into n from public.audit_log where id > v_max and action = 'subscription_updated' and company_id is null;
  r := r || format('AU1 cambio de suscripción oculto a la empresa=%s (esperado 1); ', n);
  select string_agg(distinct action, ', ') into v from public.audit_log where id > v_max;
  r := r || 'AU2 acciones: ' || coalesce(v, 'ninguna') || '; ';
  select detail into v from public.audit_log where id > v_max and action = 'shift_updated' limit 1;
  r := r || 'AU3 detalle turno: ' || coalesce(v, '-') || '; ';
  select count(*) into n from public.audit_log where id > v_max and detail ~ '[0-9]{13}';
  r := r || format('AU4 DPI copiado en bitácora=%s (esperado 0); ', n);

  raise exception 'RESULTADOS: %', r;
end $$;
