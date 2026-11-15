-- Pruebas de la foto del DPI/licencia del visitante (como cada rol real). Se deshace sola.
do $$
declare
  c_company uuid := (select id from public.companies where code = 'C2193E');
  u_admin uuid := (select id from public.profiles where email = 'admin@dag.test');
  u_sup uuid := (select id from public.profiles where email = 'supervisor@dag.test');
  u_guard uuid := (select id from public.profiles where username = 'guarda' and role = 'guard' limit 1);
  s_mine uuid; s_other uuid; e_id uuid := gen_random_uuid(); r text := ''; v text; n int; p text; v_max bigint;
begin
  select coalesce(max(id), 0) into v_max from public.audit_log;
  select gs.site_id into s_mine from public.guard_sites gs where gs.guard_id = u_guard and gs.active order by gs.site_id limit 1;
  select s.id into s_other from public.sites s where s.company_id = c_company and not exists (select 1 from public.guard_sites gs where gs.site_id = s.id and gs.guard_id = u_guard and gs.active) limit 1;
  p := c_company::text || '/' || s_mine::text || '/' || e_id::text || '.jpg';

  perform set_config('request.jwt.claims', json_build_object('sub', u_guard, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform public.register_entry(e_id, s_mine, null, jsonb_build_object('kind', 'pedestrian', 'person_name', 'Prueba Foto', 'doc_number', '1234567890101', 'doc_kind', 'dpi'), null);
  r := r || format('F1 guarda puede subir a su sitio=%s, a otro sitio=%s (esperado true/false); ',
    private.can_upload_visitor_doc(p), private.can_upload_visitor_doc(c_company::text || '/' || s_other::text || '/x.jpg'));
  r := r || format('F2 guarda puede ver la foto=%s (esperado false); ', private.can_manage_visitor_doc(p));
  begin perform public.set_entry_photo(e_id, 'otra/ruta.jpg'); r := r || 'F3 FALLA ruta ajena; ';
  exception when others then r := r || 'F3 ok ruta ajena bloqueada; '; end;
  perform public.set_entry_photo(e_id, p);
  r := r || 'F4 foto anotada; ';

  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  r := r || format('F5 supervisor ve la foto=%s (esperado false); ', private.can_manage_visitor_doc(p));
  begin perform public.clear_entry_photos(array[e_id]); r := r || 'F6 FALLA supervisor borró; ';
  exception when others then r := r || 'F6 ok supervisor no borra; '; end;

  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
  r := r || format('F7 admin ve la foto=%s; ', private.can_manage_visitor_doc(p));
  select doc_photo_path into v from public.access_entries where id = e_id;
  n := public.clear_entry_photos(array[e_id]);
  r := r || format('F8 admin ve la ruta=%s y la quita (%s); ', (v is not null)::text, n);
  execute 'reset role';
  select count(*) into n from public.audit_log where action = 'visitor_photos_deleted' and id > v_max;
  r := r || format('F9 borrado anotado en la bitácora=%s; ', n);
  raise exception 'RESULTADOS: %', r;
end $$;

-- Almacenamiento real (storage.objects) como cada rol. Se deshace sola.
do $$
declare
  c_company uuid := (select id from public.companies where code = 'C2193E');
  u_admin uuid := (select id from public.profiles where email = 'admin@dag.test');
  u_sup uuid := (select id from public.profiles where email = 'supervisor@dag.test');
  u_guard uuid := (select id from public.profiles where username = 'guarda' and role = 'guard' limit 1);
  s_mine uuid; s_other uuid; e_id uuid := gen_random_uuid(); r text := ''; n int; p text; p_bad text;
begin
  select gs.site_id into s_mine from public.guard_sites gs join public.sites s on s.id = gs.site_id
   where gs.guard_id = u_guard and gs.active and s.visitor_control and s.active order by gs.site_id limit 1;
  select s.id into s_other from public.sites s where s.company_id = c_company
   and not exists (select 1 from public.guard_sites gs where gs.site_id = s.id and gs.guard_id = u_guard and gs.active) limit 1;
  p := c_company::text || '/' || s_mine::text || '/' || e_id::text || '.jpg';
  p_bad := c_company::text || '/' || coalesce(s_other::text, gen_random_uuid()::text) || '/' || e_id::text || '.jpg';

  perform set_config('request.jwt.claims', json_build_object('sub', u_guard, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  insert into storage.objects (bucket_id, name, owner_id, metadata) values ('visitor_docs', p, u_guard::text, '{"mimetype":"image/jpeg","size":1000}');
  r := r || 'S1 guarda sube a su sitio: ok; ';
  begin
    insert into storage.objects (bucket_id, name, owner_id) values ('visitor_docs', p_bad, u_guard::text);
    r := r || 'S2 FALLA subió a sitio ajeno; ';
  exception when others then r := r || 'S2 ok sitio ajeno bloqueado; '; end;
  select count(*) into n from storage.objects where bucket_id = 'visitor_docs' and name = p;
  r := r || format('S3 guarda ve la foto=%s (esperado 0); ', n);

  perform set_config('request.jwt.claims', json_build_object('sub', u_sup, 'role', 'authenticated')::text, true);
  select count(*) into n from storage.objects where bucket_id = 'visitor_docs' and name = p;
  r := r || format('S4 supervisor ve=%s (esperado 0); ', n);

  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
  select count(*) into n from storage.objects where bucket_id = 'visitor_docs' and name = p;
  r := r || format('S5 admin ve=%s (esperado 1); ', n);
  execute 'reset role';
  raise exception 'RESULTADOS: %', r;
end $$;
