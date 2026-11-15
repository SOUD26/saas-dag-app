-- Pruebas del historial de visitas (como cada rol real). Se deshace sola.
do $$
declare
  c_company uuid := (select id from public.companies where code = 'C2193E');
  u_admin uuid := (select id from public.profiles where email = 'admin@dag.test');
  u_sup uuid := (select id from public.profiles where email = 'supervisor@dag.test');
  u_guard uuid := (select id from public.profiles where username = 'guarda' and role = 'guard' limit 1);
  s_mine uuid; c_other uuid; s_other uuid; r text := ''; n bigint; v record;
  e1 uuid := gen_random_uuid(); e2 uuid := gen_random_uuid(); e3 uuid := gen_random_uuid();
begin
  select gs.site_id into s_mine from public.guard_sites gs join public.sites s on s.id = gs.site_id
   where gs.guard_id = u_guard and gs.active and s.visitor_control and s.active order by gs.site_id limit 1;

  -- Otra empresa con un ingreso de la misma placa (no debe aparecer en la búsqueda de Seguridad Demo).
  insert into public.companies (name) values ('Prueba Aislamiento Historial') returning id into c_other;
  insert into public.sites (company_id, name, lat, lng) values (c_other, 'Sitio ajeno', 14.6, -90.5) returning id into s_other;
  insert into public.access_entries (id, company_id, site_id, kind, plate, person_name, entered_at)
  values (gen_random_uuid(), c_other, s_other, 'vehicle', 'P321XYZ', 'Ajeno', now());

  -- El guarda registra tres ingresos.
  perform set_config('request.jwt.claims', json_build_object('sub', u_guard, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.register_entry(e1, s_mine, null, jsonb_build_object('kind', 'vehicle', 'plate', 'P-321XYZ',
    'person_name', 'José Pérez', 'doc_kind', 'dpi', 'doc_number', '2567 41839 0101',
    'visitor_company_text', 'Jardinería López', 'destination', 'Casa 12'), null);
  perform public.register_entry(e2, s_mine, null, jsonb_build_object('kind', 'pedestrian',
    'person_name', 'Jose Perez', 'doc_kind', 'dpi', 'doc_number', '2567418390101',
    'visitor_company_text', 'Otra SA', 'destination', 'Oficina 3'), null);
  perform public.register_entry(e3, s_mine, null, jsonb_build_object('kind', 'vehicle', 'plate', 'p321xyz',
    'person_name', 'María Gómez'), null);
  select count(*) into n from public.search_visits('P-321');
  r := r || format('H1 guarda no ve historial=%s (esperado 0); ', n);

  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
  select count(*) into n from public.search_visits('P-321', c_company);
  r := r || format('H2 admin por placa=%s (esperado 2); ', n);
  select count(*) into n from public.search_visits('P-321');
  r := r || format('H3 admin sin filtro de empresa no ve la ajena=%s (esperado 2); ', n);
  select total_visits, total_people, total_vehicles into v from public.search_visits('P-321', c_company) limit 1;
  r := r || format('H4 resumen placa visitas=%s personas=%s vehículos=%s (esperado 2/2/1); ', v.total_visits, v.total_people, v.total_vehicles);
  select count(*) into n from public.search_visits('7418390', c_company) where id in (e1, e2, e3);
  r := r || format('H5 admin por parte del DPI=%s (esperado 2); ', n);
  select count(*) into n from public.search_visits('jose perez', c_company) where id in (e1, e2, e3);
  r := r || format('H6 nombre sin tildes=%s (esperado 2); ', n);
  select count(*) into n from public.search_visits('JARDINERIA', c_company) where id in (e1, e2, e3);
  r := r || format('H7 empresa de donde viene=%s (esperado 1); ', n);
  select count(*) into n from public.search_visits('oficina 3', c_company) where id in (e1, e2, e3);
  r := r || format('H8 a donde va=%s (esperado 1); ', n);
  select count(*) into n from public.search_visits('P-321', c_company, s_mine, now() - interval '1 hour', now() + interval '1 hour');
  r := r || format('H9 con sitio y período=%s (esperado 2); ', n);
  select count(*) into n from public.search_visits('P-321', c_company, null, now() + interval '1 day');
  r := r || format('H10 período sin visitas=%s (esperado 0); ', n);

  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  select count(*) into n from public.search_visits('P-321', c_company);
  r := r || format('H11 supervisor (sitio suyo=%s) ve=%s; ', private.sees_site(s_mine), n);
  select count(*) into n from public.search_visits('Ajeno');
  r := r || format('H12 supervisor no ve otra empresa=%s (esperado 0); ', n);
  execute 'reset role';
  raise exception 'RESULTADOS: %', r;
end $$;
