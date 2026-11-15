-- Pruebas del módulo del guarda: sitios con aprobación, puestos, implementos, relevo y alertas
-- de tres niveles. Se corren como cada rol real (no como dueño de la base).
-- Cómo correrlas: pegar en el editor SQL de Supabase (o execute_sql). Usan los datos demo ("Seguridad Demo").
-- Todo se deshace al final: el bloque termina con una excepción que trae el informe ("RESULTADOS: ...").
do $$
declare
  c_company uuid := (select id from public.companies where code = 'C2193E');
  u_admin uuid := (select id from public.profiles where email = 'admin@dag.test');
  u_sup uuid := (select id from public.profiles where email = 'supervisor@dag.test');
  u_guard uuid := (select id from public.profiles where username = 'guarda' and role = 'guard' limit 1);
  u_guard2 uuid := (select id from public.profiles where username = 'cmendez' limit 1);
  u_guard3 uuid := (select id from public.profiles where username = 'jramirez' limit 1);
  u_client uuid := (select id from public.profiles where email = 'cliente@dag.test');
  b_company uuid := gen_random_uuid();
  b_admin uuid := gen_random_uuid();
  t_radio uuid; t_ammo uuid; t_flash uuid; t_keys uuid; t_wl uuid;
  s_prop uuid; s_adm uuid;
  p_a uuid; p_b uuid;
  i_radio uuid; i_ammo uuid; i_flash uuid; i_keys uuid;
  c_ana uuid;
  v_payload jsonb; v_payload2 jsonb;
  v_verif uuid;
  v_max bigint;
  r text := '';
  n int; m int;
  v text;
  h record;
begin
  -- ===== Preparación (dueño de la base) =====
  select coalesce(max(id), 0) into v_max from public.audit_log;
  insert into public.companies (id, name) values (b_company, 'Empresa Prueba B');
  select count(*) into n from public.implement_types where company_id = b_company;
  r := r || format('P1 empresa nueva trae implementos=%s (esperado 18); ', n);
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (b_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'adminb@prueba.invalid', '', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, company_id, role, full_name, email) values (b_admin, b_company, 'company_admin', 'Admin B', 'adminb@prueba.invalid');
  select id into t_radio from public.implement_types where company_id = c_company and name = 'Radio';
  select id into t_ammo from public.implement_types where company_id = c_company and name = 'Munición';
  select id into t_flash from public.implement_types where company_id = c_company and name = 'Linterna';
  select id into t_keys from public.implement_types where company_id = c_company and name = 'Llaves';
  select id into t_wl from public.document_types where company_id = c_company and key = 'weapon_license';
  insert into public.documents (type_id, profile_id, number, expires_on) values (t_wl, u_guard2, 'LIC-PRUEBA', current_date + 200);

  v_payload := jsonb_build_object(
    'name', '  Prueba   Propuesta ', 'address', 'Km 15 carretera', 'lat', 14.6, 'lng', -90.5, 'radius_m', 120,
    'proposed_client_name', 'Cliente Nuevo Prueba',
    'rounds_required', true, 'rounds_every_minutes', 120,
    'survey', jsonb_build_object('riesgo', 'alto', 'senal', 'debil'),
    'assign_guards', true,
    'posts', jsonb_build_array(
       jsonb_build_object('name', 'Garita', 'cover_from', '07:00', 'cover_to', '07:00', 'shift_hours', 24,
         'guards_required', 3, 'orders', 'No dejar pasar sin autorización', 'guards', jsonb_build_array(u_guard),
         'implements', jsonb_build_array(
            jsonb_build_object('type_id', t_radio, 'label', 'Motorola', 'serial', 'R-1'),
            jsonb_build_object('type_id', t_ammo, 'quantity', 5))),
       jsonb_build_object('name', 'Ronda', 'cover_from', '18:00', 'cover_to', '06:00', 'shift_hours', 12,
         'days', jsonb_build_array(1, 2, 3, 4, 5),
         'implements', jsonb_build_array(
            jsonb_build_object('type_id', t_flash),
            jsonb_build_object('type_id', t_keys, 'quantity', 3)))),
    'contacts', jsonb_build_array(
       jsonb_build_object('full_name', 'Ana Administradora', 'job_title', 'Administradora', 'phone', '5555-0000',
         'email', 'ANA@Prueba.invalid', 'is_admin', true, 'trained_at', current_date::text)));

  -- ===== Supervisor propone =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  begin
    s_prop := public.save_site(null, v_payload, false);
    select status || '/' || active::text || '/' || name into v from public.sites where id = s_prop;
    r := r || format('S1 propuesta guardada: %s (esperado draft/false/Prueba Propuesta); ', v);
  exception when others then r := r || 'S1 FALLÓ ' || sqlerrm || '; '; end;

  select id into p_a from public.site_posts where site_id = s_prop and name = 'Garita';
  select id into p_b from public.site_posts where site_id = s_prop and name = 'Ronda';
  select id into i_radio from public.site_implements where post_id = p_a and type_id = t_radio;
  select id into i_ammo from public.site_implements where post_id = p_a and type_id = t_ammo;
  select id into i_flash from public.site_implements where post_id = p_b and type_id = t_flash;
  select id into i_keys from public.site_implements where post_id = p_b and type_id = t_keys;
  select id into c_ana from public.site_contacts where site_id = s_prop;
  select count(*) into n from public.site_implements where site_id = s_prop;
  r := r || format('S2 supervisor ve sus puestos y %s implementos (esperado 4); ', n);
  select email || ' / ' || phone into v from public.site_contacts where id = c_ana;
  r := r || format('S3 contacto normalizado: %s; ', v);
  select count(*) into n from public.guard_sites where site_id = s_prop;
  r := r || format('S4 el supervisor no asigna guardas: asignaciones=%s (esperado 0); ', n);

  v_payload2 := v_payload || jsonb_build_object(
    'posts', jsonb_build_array(
       jsonb_build_object('id', p_a, 'name', 'Garita', 'cover_from', '07:00', 'cover_to', '07:00', 'shift_hours', 24,
         'guards_required', 3, 'orders', 'No dejar pasar sin autorización', 'guards', jsonb_build_array(u_guard),
         'implements', jsonb_build_array(
            jsonb_build_object('id', i_radio, 'type_id', t_radio, 'label', 'Motorola', 'serial', 'R-1'),
            jsonb_build_object('id', i_ammo, 'type_id', t_ammo, 'quantity', 5))),
       jsonb_build_object('id', p_b, 'name', 'Ronda', 'cover_from', '18:00', 'cover_to', '06:00', 'shift_hours', 12,
         'days', jsonb_build_array(1, 2, 3, 4, 5), 'guards', jsonb_build_array(u_guard2),
         'implements', jsonb_build_array(
            jsonb_build_object('id', i_flash, 'type_id', t_flash),
            jsonb_build_object('id', i_keys, 'type_id', t_keys, 'quantity', 3)))),
    'contacts', jsonb_build_array(
       jsonb_build_object('id', c_ana, 'full_name', 'Ana Administradora', 'job_title', 'Administradora',
         'phone', '5555-0000', 'email', 'ana@prueba.invalid', 'is_admin', true, 'trained_at', current_date::text)));

  begin
    perform public.save_site(s_prop, v_payload2 || jsonb_build_object('visitor_control', true), false);
    r := r || 'S5 FALLA: activó control de visitas sin el módulo; ';
  exception when others then r := r || 'S5 ok bloqueado (' || sqlerrm || '); '; end;

  begin
    perform public.approve_site(s_prop);
    r := r || 'S6 FALLA: el supervisor aprobó; ';
  exception when others then r := r || 'S6 ok bloqueado; '; end;

  begin
    update public.sites set name = 'Cambiado' where id = s_prop;
    r := r || 'S7 FALLA: editó el sitio directo; ';
  exception when others then r := r || 'S7 ok bloqueado (' || sqlstate || '); '; end;

  begin
    select count(*) into n from public.client_options();
    r := r || format('S8 clientes para elegir=%s (esperado >0); ', n);
  exception when others then r := r || 'S8 FALLÓ ' || sqlerrm || '; '; end;

  begin
    perform public.save_site(s_prop, v_payload2, true);
    select status into v from public.sites where id = s_prop;
    select count(*) into n from public.site_posts where site_id = s_prop;
    r := r || format('S9 enviada: %s, puestos=%s (esperado pending y 2); ', v, n);
  exception when others then r := r || 'S9 FALLÓ ' || sqlerrm || '; '; end;

  begin
    insert into public.implement_types (company_id, name) values (c_company, 'Dron');
    r := r || 'S10 FALLA: el supervisor agregó al catálogo; ';
  exception when others then r := r || 'S10 ok bloqueado; '; end;

  -- ===== Administrador revisa =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
  begin
    perform public.return_site(s_prop, 'Falta el teléfono del conserje');
    select status || ' / ' || coalesce(review_note, '-') into v from public.sites where id = s_prop;
    r := r || format('A1 devuelta: %s; ', v);
  exception when others then r := r || 'A1 FALLÓ ' || sqlerrm || '; '; end;

  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  begin
    perform public.save_site(s_prop, v_payload2, true);
    select status into v from public.sites where id = s_prop;
    r := r || format('S11 corregida y reenviada: %s (esperado pending); ', v);
  exception when others then r := r || 'S11 FALLÓ ' || sqlerrm || '; '; end;

  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
  begin
    perform public.save_site(s_prop, v_payload2, false);
    select count(*) into n from public.guard_sites where site_id = s_prop and active;
    select count(*) into m from public.guard_sites where site_id = s_prop and active and post_id = p_a and guard_id = u_guard;
    r := r || format('A2 admin asigna por puesto: activos=%s, guarda en Garita=%s (esperado 2 y 1); ', n, m);
  exception when others then r := r || 'A2 FALLÓ ' || sqlerrm || '; '; end;

  begin
    perform public.save_site(s_prop, v_payload2 || jsonb_build_object('posts', jsonb_build_array(
      jsonb_build_object('id', p_a, 'name', 'Garita', 'guards', jsonb_build_array(u_guard),
        'implements', jsonb_build_array(jsonb_build_object('id', i_radio, 'type_id', t_radio),
                                        jsonb_build_object('id', i_ammo, 'type_id', t_ammo, 'quantity', 5))),
      jsonb_build_object('id', p_b, 'name', 'Ronda', 'guards', jsonb_build_array(u_guard),
        'implements', jsonb_build_array(jsonb_build_object('id', i_flash, 'type_id', t_flash),
                                        jsonb_build_object('id', i_keys, 'type_id', t_keys, 'quantity', 3))))), false);
    r := r || 'A3 FALLA: un guarda quedó en dos puestos del mismo sitio; ';
  exception when others then r := r || 'A3 ok bloqueado (' || sqlerrm || '); '; end;

  begin
    perform public.approve_site(s_prop);
    select s.status || '/' || s.active::text || '/' || coalesce(c.name, 'sin cliente') into v
      from public.sites s left join public.clients c on c.id = s.client_id where s.id = s_prop;
    r := r || format('A4 aprobada: %s (esperado approved/true/Cliente Nuevo Prueba); ', v);
  exception when others then r := r || 'A4 FALLÓ ' || sqlerrm || '; '; end;

  begin
    s_adm := public.save_site(null, jsonb_build_object('name', 'Prueba Admin', 'lat', 14.61, 'lng', -90.51,
              'posts', jsonb_build_array(jsonb_build_object('name', 'Recepción'))), false);
    select status || '/' || active::text into v from public.sites where id = s_adm;
    r := r || format('A5 sitio creado por el admin: %s (esperado approved/true); ', v);
  exception when others then r := r || 'A5 FALLÓ ' || sqlerrm || '; '; end;

  begin
    perform public.save_site(null, jsonb_build_object('name', 'Sin puestos', 'lat', 14.6, 'lng', -90.5, 'posts', '[]'::jsonb), false);
    r := r || 'A6 FALLA: guardó un sitio sin puestos; ';
  exception when others then r := r || 'A6 ok bloqueado (' || sqlerrm || '); '; end;

  begin
    insert into public.sites (company_id, name, lat, lng) values (c_company, 'Directo', 14.6, -90.5);
    r := r || 'A7 FALLA: insertó un sitio directo; ';
  exception when others then r := r || 'A7 ok bloqueado (' || sqlstate || '); '; end;

  begin
    update public.sites set active = false where id = s_adm;
    update public.sites set active = true where id = s_adm;
    r := r || 'A8 admin activa y desactiva; ';
  exception when others then r := r || 'A8 FALLÓ ' || sqlerrm || '; '; end;

  begin
    insert into public.implement_types (company_id, name, severity) values (c_company, 'Dron', 'orange');
    r := r || 'A9 admin agrega al catálogo; ';
  exception when others then r := r || 'A9 FALLÓ ' || sqlerrm || '; '; end;

  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  begin
    perform public.save_site(s_prop, v_payload2, false);
    r := r || 'S12 FALLA: el supervisor editó un sitio aprobado; ';
  exception when others then r := r || 'S12 ok bloqueado; '; end;

  -- ===== Otra empresa y cliente =====
  perform set_config('request.jwt.claims', json_build_object('sub', b_admin, 'role', 'authenticated')::text, true);
  select count(*) into n from public.sites where id in (s_prop, s_adm);
  select count(*) into m from public.implement_types where company_id = c_company;
  r := r || format('B1 otra empresa ve sitios=%s catálogo=%s (esperado 0 y 0); ', n, m);
  begin
    perform public.save_site(s_prop, v_payload2, false);
    r := r || 'B2 FALLA: otra empresa editó el sitio; ';
  exception when others then r := r || 'B2 ok bloqueado; '; end;
  begin
    perform public.client_options(c_company);
    r := r || 'B3 FALLA: otra empresa listó clientes; ';
  exception when others then r := r || 'B3 ok bloqueado; '; end;

  perform set_config('request.jwt.claims', json_build_object('sub', u_client, 'role', 'authenticated')::text, true);
  select count(*) into n from public.site_contacts;
  select count(*) into m from public.site_implements;
  r := r || format('C1 cliente ve contactos=%s implementos=%s (esperado 0 y 0); ', n, m);

  -- ===== Guardas: lista a ciegas y relevo =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_guard, 'role', 'authenticated')::text, true);
  select count(*) into n from public.site_implements where site_id = s_prop;
  select count(*) into m from public.post_checklist(p_a);
  r := r || format('G1 guarda lee implementos directo=%s, lista a ciegas=%s (esperado 0 y 2); ', n, m);

  begin
    select * into h from public.submit_handover(p_a, 'reception', jsonb_build_array(
      jsonb_build_object('implement_id', i_radio, 'status', 'ok'),
      jsonb_build_object('implement_id', i_ammo, 'status', 'ok', 'counted', 5)), null, null, null, true);
    r := r || format('H1 recibe munición sin licencia: %s/%s (esperado ok/red); ', h.r_result, coalesce(h.r_severity, '-'));
  exception when others then r := r || 'H1 FALLÓ ' || sqlerrm || '; '; end;

  begin
    select * into h from public.submit_handover(p_a, 'delivery', jsonb_build_array(
      jsonb_build_object('implement_id', i_radio, 'status', 'ok'),
      jsonb_build_object('implement_id', i_ammo, 'status', 'ok', 'counted', 5)));
    r := r || format('H2 entrega sin novedad: %s/%s (esperado ok/-); ', h.r_result, coalesce(h.r_severity, '-'));
  exception when others then r := r || 'H2 FALLÓ ' || sqlerrm || '; '; end;

  begin
    perform public.submit_handover(p_a, 'delivery', jsonb_build_array(jsonb_build_object('implement_id', i_radio, 'status', 'ok')));
    r := r || 'H3 FALLA: aceptó una lista incompleta; ';
  exception when others then r := r || 'H3 ok bloqueado; '; end;

  perform set_config('request.jwt.claims', json_build_object('sub', u_guard2, 'role', 'authenticated')::text, true);
  begin
    select * into h from public.submit_handover(p_a, 'reception', jsonb_build_array(
      jsonb_build_object('implement_id', i_radio, 'status', 'missing'),
      jsonb_build_object('implement_id', i_ammo, 'status', 'ok', 'counted', 4)));
    r := r || format('H4 recepción que no cuadra: %s/%s (esperado mismatch/red) [%s]; ',
                     h.r_result, coalesce(h.r_severity, '-'), replace(coalesce(h.r_detail, ''), E'\n', ' | '));
  exception when others then r := r || 'H4 FALLÓ ' || sqlerrm || '; '; end;

  begin
    select * into h from public.submit_handover(p_a, 'delivery', jsonb_build_array(
      jsonb_build_object('implement_id', i_radio, 'status', 'missing'),
      jsonb_build_object('implement_id', i_ammo, 'status', 'ok', 'counted', 4)));
    r := r || format('H5 entrega con faltante ya reportado: %s/%s (esperado issues/-); ', h.r_result, coalesce(h.r_severity, '-'));
  exception when others then r := r || 'H5 FALLÓ ' || sqlerrm || '; '; end;

  begin
    select * into h from public.submit_handover(p_a, 'reception', jsonb_build_array(
      jsonb_build_object('implement_id', i_radio, 'status', 'missing'),
      jsonb_build_object('implement_id', i_ammo, 'status', 'ok', 'counted', 4)));
    r := r || format('H6 recepción que cuadra (con licencia): %s/%s (esperado issues/-); ', h.r_result, coalesce(h.r_severity, '-'));
  exception when others then r := r || 'H6 FALLÓ ' || sqlerrm || '; '; end;

  begin
    perform public.submit_handover(p_b, 'reception', jsonb_build_array(
      jsonb_build_object('implement_id', i_flash, 'status', 'ok'),
      jsonb_build_object('implement_id', i_keys, 'status', 'ok', 'counted', 3)));
  exception when others then r := r || 'H7a FALLÓ ' || sqlerrm || '; '; end;
  perform set_config('request.jwt.claims', json_build_object('sub', u_guard, 'role', 'authenticated')::text, true);
  begin
    select * into h from public.submit_handover(p_b, 'reception', jsonb_build_array(
      jsonb_build_object('implement_id', i_flash, 'status', 'ok'),
      jsonb_build_object('implement_id', i_keys, 'status', 'ok', 'counted', 3)));
    r := r || format('H7 relevo sin entrega: %s/%s (esperado ok/orange); ', h.r_result, coalesce(h.r_severity, '-'));
  exception when others then r := r || 'H7 FALLÓ ' || sqlerrm || '; '; end;

  begin
    select r_id into v_verif from public.register_verification(s_prop, null, 'shift_start', 'password_fallback',
                                                               null, null, 14.6, -90.5, 'poca luz', null);
  exception when others then r := r || 'V0 FALLÓ ' || sqlerrm || '; '; end;

  perform set_config('request.jwt.claims', json_build_object('sub', u_guard3, 'role', 'authenticated')::text, true);
  begin
    perform public.submit_handover(p_b, 'delivery', jsonb_build_array(
      jsonb_build_object('implement_id', i_flash, 'status', 'ok'),
      jsonb_build_object('implement_id', i_keys, 'status', 'ok', 'counted', 3)));
    r := r || 'H8 FALLA: un guarda ajeno entregó; ';
  exception when others then r := r || 'H8 ok bloqueado; '; end;
  begin
    perform public.post_checklist(p_b);
    r := r || 'H9 FALLA: un guarda ajeno vio la lista; ';
  exception when others then r := r || 'H9 ok bloqueado; '; end;

  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  begin
    select * into h from public.submit_handover(p_b, 'inventory', jsonb_build_array(
      jsonb_build_object('implement_id', i_flash, 'status', 'damaged', 'note', 'Sin baterías'),
      jsonb_build_object('implement_id', i_keys, 'status', 'ok', 'counted', 3)));
    r := r || format('H10 inventario del supervisor: %s/%s (esperado issues/yellow); ', h.r_result, coalesce(h.r_severity, '-'));
  exception when others then r := r || 'H10 FALLÓ ' || sqlerrm || '; '; end;
  select count(*) into n from public.alerts where site_id = s_prop;
  select string_agg(severity || ':' || title, ' | ' order by severity) into v from public.alerts where site_id = s_prop;
  r := r || format('H11 supervisor ve alertas del sitio=%s (esperado 5): %s; ', n, v);
  select count(*) into n from public.post_handovers where site_id = s_prop;
  r := r || format('H12 supervisor ve actas=%s (esperado 8); ', n);
  begin
    select id::text into v from public.alerts where site_id = s_prop limit 1;
    perform public.review_alert(v::uuid, 'justified');
    r := r || 'R1 FALLA: el supervisor revisó una alerta; ';
  exception when others then r := r || 'R1 ok bloqueado; '; end;

  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
  begin
    select id::text into v from public.alerts where site_id = s_prop and severity = 'yellow' limit 1;
    perform public.review_alert(v::uuid, 'justified', 'Se cambian baterías');
    select review_outcome into v from public.alerts where id = v::uuid;
    perform public.reopen_alert((select id from public.alerts where site_id = s_prop and severity = 'yellow' limit 1));
    r := r || format('R2 admin revisa (%s) y reabre; ', v);
  exception when others then r := r || 'R2 FALLÓ ' || sqlerrm || '; '; end;

  perform set_config('request.jwt.claims', json_build_object('sub', u_guard, 'role', 'authenticated')::text, true);
  select count(*) into n from public.alerts;
  select count(*) into m from public.post_handovers;
  r := r || format('G2 guarda ve alertas=%s y actas propias=%s (esperado 0 y 3); ', n, m);

  perform set_config('request.jwt.claims', json_build_object('sub', b_admin, 'role', 'authenticated')::text, true);
  select count(*) into n from public.alerts where company_id = c_company;
  select count(*) into m from public.post_handovers where company_id = c_company;
  r := r || format('B4 otra empresa ve alertas=%s actas=%s (esperado 0 y 0); ', n, m);
  execute 'reset role';

  -- ===== Comprobaciones finales (dueño) =====
  select severity into v from public.alerts where source = 'verification' and source_id = v_verif;
  r := r || format('V1 entrada sin cara → alerta %s (esperado orange); ', coalesce(v, '-'));
  select string_agg(status || coalesce('(' || last_counted || ')', ''), ', ' order by type_id) into v
    from public.site_implements where site_id = s_prop;
  r := r || format('I1 estado final de implementos: %s; ', v);
  select string_agg(distinct action, ', ') into v from public.audit_log where id > v_max;
  r := r || 'AU1 acciones: ' || coalesce(v, '-') || '; ';
  select count(*) into n from public.audit_log where id > v_max and action = 'site_implement_updated';
  r := r || format('AU2 cambios de implementos en bitácora=%s (los de relevos no se repiten); ', n);
  select count(*) into n from public.audit_log where id > v_max and detail ilike '%ana@%';
  r := r || format('AU3 correo del contacto en bitácora=%s (esperado 0); ', n);

  raise exception 'RESULTADOS: %', r;
end $$;
