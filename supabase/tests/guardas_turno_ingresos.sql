-- Pruebas del turno sin señal, ingresos/salidas y bitácora (como cada rol real).
-- Todo se deshace al final: el bloque termina con una excepción que trae el informe ("RESULTADOS: ...").
do $$
declare
  c_company uuid := (select id from public.companies where code = 'C2193E');
  u_admin uuid := (select id from public.profiles where email = 'admin@dag.test');
  u_sup uuid := (select id from public.profiles where email = 'supervisor@dag.test');
  u_guard uuid := (select id from public.profiles where username = 'guarda' and role = 'guard' limit 1);
  b_company uuid := gen_random_uuid();
  b_admin uuid := gen_random_uuid();
  s_mine uuid;
  s_other uuid;
  p_mine uuid;
  ctx jsonb;
  v_id uuid := gen_random_uuid();
  e_id uuid := gen_random_uuid();
  e2_id uuid := gen_random_uuid();
  l_id uuid := gen_random_uuid();
  h_id uuid := gen_random_uuid();
  r text := '';
  n int; m int;
  v text;
  h record;
begin
  select gs.site_id, gs.post_id into s_mine, p_mine from public.guard_sites gs
   where gs.guard_id = u_guard and gs.active order by gs.site_id limit 1;
  select s.id into s_other from public.sites s
   where s.company_id = c_company and s.active
     and not exists (select 1 from public.guard_sites gs where gs.site_id = s.id and gs.guard_id = u_guard and gs.active)
   limit 1;
  insert into public.companies (id, name) values (b_company, 'Empresa Prueba B');
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
  values (b_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'adminb@prueba.invalid', '', now(), now(), now(), '{}', '{}');
  insert into public.profiles (id, company_id, role, full_name, email) values (b_admin, b_company, 'company_admin', 'Admin B', 'adminb@prueba.invalid');
  select count(*) into n from public.visitor_companies where company_id = b_company;
  r := r || format('P1 empresa nueva trae empresas visitantes=%s (esperado 17); ', n);
  insert into public.shifts (company_id, site_id, guard_id, starts_at, ends_at, post_id)
  values (c_company, s_mine, u_guard, now() - interval '1 hour', now() + interval '11 hours', p_mine);

  -- ===== Guarda =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_guard, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  ctx := public.guard_context();
  r := r || format('G1 contexto: sitios=%s, supervisores del primero=%s, turnos=%s, cara exigida=%s; ',
                   jsonb_array_length(ctx -> 'sites'),
                   jsonb_array_length(ctx -> 'sites' -> 0 -> 'supervisors'),
                   jsonb_array_length(ctx -> 'shifts'), ctx -> 'company' ->> 'face_required');

  select * into h from public.record_verification(v_id, s_mine, null, 'shift_start', 'password_fallback', null, null,
                        (select lat from public.sites where id = s_mine), (select lng from public.sites where id = s_mine),
                        'reconocimiento facial no instalado', null, now() - interval '50 minutes');
  select * into h from public.record_verification(v_id, s_mine, null, 'shift_start', 'password_fallback', null, null,
                        (select lat from public.sites where id = s_mine), (select lng from public.sites where id = s_mine),
                        'reconocimiento facial no instalado', null, now() - interval '50 minutes');
  r := r || format('G2 inicio de turno con contraseña + GPS: alerta=%s (esperado false); ', h.r_flagged);

  begin
    perform public.register_entry(e_id, s_mine, p_mine, jsonb_build_object(
      'kind', 'vehicle', 'plate', 'p-123 abc', 'person_name', 'Juan  Pérez', 'doc_kind', 'dpi',
      'doc_number', '1234 56789 0101', 'visitor_company_id',
      (select id from public.visitor_companies where company_id = c_company and name = 'DHL'),
      'destination', 'Casa 12'), now() - interval '10 minutes');
    perform public.register_entry(e_id, s_mine, p_mine, jsonb_build_object('kind', 'vehicle', 'plate', 'P123ABC'), null);
    r := r || 'G3 ingreso guardado (y repetido sin duplicar); ';
  exception when others then r := r || 'G3 FALLÓ ' || sqlerrm || '; '; end;
  begin
    perform public.register_entry(e2_id, s_mine, p_mine, jsonb_build_object('kind', 'pedestrian'), null);
    r := r || 'G4 FALLA: aceptó un peatón sin nombre ni documento; ';
  exception when others then r := r || 'G4 ok bloqueado (' || sqlerrm || '); '; end;
  begin
    perform public.register_entry(gen_random_uuid(), s_other, null, jsonb_build_object('kind', 'vehicle', 'plate', 'P555XYZ'), null);
    r := r || 'G5 FALLA: registró ingreso en un sitio ajeno; ';
  exception when others then r := r || 'G5 ok bloqueado; '; end;

  select count(*) into n from public.site_inside(s_mine);
  select plate || ' / ' || coalesce(doc_last4, '-') || ' / ' || coalesce(company_name, '-') into v
    from public.site_inside(s_mine) where id = e_id;
  select count(*) into m from public.access_entries;
  r := r || format('G6 dentro=%s: %s; lectura directa de ingresos=%s (esperado 0); ', n, v, m);

  begin
    perform public.register_exit(e_id, now() - interval '1 hour', null);
    perform public.register_exit(e_id, now(), null);
    select count(*) into n from public.site_inside(s_mine) where id = e_id;
    r := r || format('G7 salida marcada (dentro ahora=%s, esperado 0); ', n);
  exception when others then r := r || 'G7 FALLÓ ' || sqlerrm || '; '; end;

  begin
    perform public.add_log_entry(l_id, s_mine, p_mine, 'incidente', 'Se fue la luz en la garita', now(), null);
    perform public.add_log_entry(l_id, s_mine, p_mine, 'incidente', 'Se fue la luz en la garita', now(), null);
    r := r || 'G8 incidente en bitácora (repetido sin duplicar); ';
  exception when others then r := r || 'G8 FALLÓ ' || sqlerrm || '; '; end;
  begin
    perform public.add_log_entry(gen_random_uuid(), s_mine, p_mine, 'novedad', '  ', now(), null);
    r := r || 'G9 FALLA: aceptó una novedad vacía; ';
  exception when others then r := r || 'G9 ok bloqueado; '; end;
  select count(*) into n from public.site_log where site_id = s_mine;
  r := r || format('G10 el guarda lee la bitácora del sitio=%s; ', n);

  begin
    select * into h from public.record_handover(h_id, p_mine, 'reception',
      (select coalesce(jsonb_agg(jsonb_build_object('implement_id', c.implement_id, 'status', 'ok',
                                 'counted', case when c.tracking = 'count' then 3 end)), '[]'::jsonb)
         from public.post_checklist(p_mine) c), null, null, null, true, null, null, now());
    select * into h from public.record_handover(h_id, p_mine, 'reception', '[]'::jsonb);
    select count(*) into n from public.post_handovers where client_id = h_id;
    r := r || format('G11 recepción desde el teléfono sin duplicar: actas=%s (esperado 1); ', n);
  exception when others then r := r || 'G11 FALLÓ ' || sqlerrm || '; '; end;

  select private.can_view_person(u_sup)::text into v;
  r := r || format('G12 el guarda ve la foto de su supervisor=%s; ', v);
  select private.can_view_person(u_admin)::text into v;
  r := r || format('G13 el guarda ve la foto del administrador=%s (esperado false); ', v);

  -- ===== Supervisor y administrador =====
  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  select coalesce(doc_number, '-') into v from public.access_entries where id = e_id;
  select count(*) into n from public.alerts where source = 'other' and source_id = l_id;
  r := r || format('S1 supervisor ve el documento completo=%s y la alerta del incidente=%s; ', v, n);
  begin
    insert into public.visitor_companies (company_id, name) values (c_company, 'Jardinería López');
    r := r || 'S2 supervisor agrega empresa visitante; ';
  exception when others then r := r || 'S2 FALLÓ ' || sqlerrm || '; '; end;

  perform set_config('request.jwt.claims', json_build_object('sub', b_admin, 'role', 'authenticated')::text, true);
  select count(*) into n from public.access_entries where company_id = c_company;
  select count(*) into m from public.site_log where company_id = c_company;
  r := r || format('B1 otra empresa ve ingresos=%s bitácora=%s (esperado 0 y 0); ', n, m);
  begin
    perform public.site_inside(s_mine);
    r := r || 'B2 FALLA: otra empresa vio quién está dentro; ';
  exception when others then r := r || 'B2 ok bloqueado; '; end;
  execute 'reset role';

  select status || ' · llegada ' || to_char(arrived_at at time zone 'America/Guatemala', 'HH24:MI')
    into v from public.shift_log where guard_id = u_guard and site_id = s_mine order by starts_at desc limit 1;
  r := r || format('T1 la llegada usa la hora del teléfono: %s (hace 50 min); ', v);
  select offline::text || '/' || flagged::text into v from public.shift_verifications where client_id = v_id;
  r := r || format('T2 verificación sin conexión/alerta=%s (esperado true/false); ', v);
  select plate || ' · ' || doc_number || ' · ' || person_name || ' · offline=' || entry_offline::text into v
    from public.access_entries where id = e_id;
  r := r || format('T3 ingreso normalizado: %s; ', v);
  select (exited_at >= entered_at)::text into v from public.access_entries where id = e_id;
  r := r || format('T4 salida nunca antes del ingreso=%s; ', v);

  raise exception 'RESULTADOS: %', r;
end $$;
