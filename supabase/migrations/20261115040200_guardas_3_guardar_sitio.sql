-- Módulo del guarda (3/5): guardar el sitio completo de una vez (todo o nada).
-- save_site(sitio, datos, enviar):
--   * Administrador de la empresa (o súper admin): crea sitios ya aprobados y edita cualquiera.
--     Si los datos traen "assign_guards": true, también asigna guardas por puesto.
--   * Supervisor: crea propuestas (borrador, o "por aprobar" si enviar = true) y solo edita
--     las suyas mientras no estén aprobadas. Queda como supervisor del sitio.
-- Datos (jsonb): name, address, lat, lng, radius_m, client_id | proposed_client_name,
--   rounds_required, rounds_every_minutes, visitor_control, survey{},
--   posts[{id?, name, cover_from, cover_to, shift_hours, days[], guards_required, orders,
--          implements[{id?, type_id, label, serial, quantity}], guards[ids]}],
--   contacts[{id?, full_name, job_title, phone, email, is_admin, trained_at}],
--   company_id (solo súper admin, al crear).
-- Lo que no viene en la lista (puestos, implementos, contactos) se desactiva, nunca se borra.

create or replace function public.save_site(p_site_id uuid, p_payload jsonb, p_submit boolean default false)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_role public.app_role := private.user_role();
  v_new boolean := p_site_id is null;
  v_company uuid;
  v_site public.sites%rowtype;
  v_admin boolean;
  v_id uuid;
  v_status text;
  v_name text;
  v_lat double precision;
  v_lng double precision;
  v_radius int;
  v_client uuid;
  v_client_name text;
  v_rounds boolean;
  v_rounds_every int;
  v_visitors boolean;
  v_survey jsonb;
  v_assign_on boolean;
  v_assign jsonb := '{}'::jsonb;   -- guarda -> puesto
  p jsonb;
  i jsonb;
  c jsonb;
  g text;
  v_post_id uuid;
  v_post public.site_posts%rowtype;
  v_pname text;
  v_from time;
  v_to time;
  v_hours int;
  v_req int;
  v_days smallint[];
  v_orders text;
  v_sort int := 0;
  v_type public.implement_types%rowtype;
  v_impl uuid;
  v_qty int;
  v_contact uuid;
  v_cname text;
  v_trained date;
  v_keep_posts uuid[] := '{}';
  v_keep_impl uuid[] := '{}';
  v_keep_contacts uuid[] := '{}';
begin
  if v_role is null or v_role not in ('super_admin', 'company_admin', 'supervisor') then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'datos inválidos' using errcode = '22023';
  end if;

  -- ---- Empresa y permisos ----
  if v_new then
    if v_role = 'super_admin' then
      v_company := private.try_uuid(p_payload ->> 'company_id');
      if v_company is null or not exists (select 1 from public.companies where id = v_company) then
        raise exception 'indica la empresa' using errcode = '22023';
      end if;
    else
      v_company := private.user_company();
    end if;
  else
    select * into v_site from public.sites where id = p_site_id for update;
    if not found then
      raise exception 'sitio no encontrado' using errcode = '42501';
    end if;
    v_company := v_site.company_id;
  end if;

  v_admin := private.is_admin_of(v_company);
  if not v_admin then
    if v_role <> 'supervisor' or v_company is distinct from private.user_company() then
      raise exception 'no autorizado' using errcode = '42501';
    end if;
    if not v_new and (v_site.proposed_by is distinct from v_uid or v_site.status = 'approved') then
      raise exception 'solo puedes cambiar tus propuestas que aún no están aprobadas' using errcode = '42501';
    end if;
  end if;

  -- ---- Datos del sitio ----
  v_name := private.norm_text(p_payload ->> 'name');
  if v_name is null then
    raise exception 'escribe el nombre del sitio' using errcode = '22023';
  end if;
  begin
    v_lat := (p_payload ->> 'lat')::double precision;
    v_lng := (p_payload ->> 'lng')::double precision;
    v_radius := coalesce((p_payload ->> 'radius_m')::int, 100);
  exception when others then
    raise exception 'la ubicación no es válida' using errcode = '22023';
  end;
  if v_lat is null or v_lng is null or v_lat not between -90 and 90 or v_lng not between -180 and 180 then
    raise exception 'marca la ubicación del sitio en el mapa' using errcode = '22023';
  end if;
  if v_radius not between 10 and 5000 then
    raise exception 'el perímetro debe estar entre 10 y 5000 metros' using errcode = '22023';
  end if;

  v_client := private.try_uuid(p_payload ->> 'client_id');
  if v_client is not null and not exists (
       select 1 from public.clients cl where cl.id = v_client and cl.company_id = v_company) then
    raise exception 'cliente inválido' using errcode = '22023';
  end if;
  v_client_name := case when v_client is null then private.norm_text(p_payload ->> 'proposed_client_name') end;

  begin
    v_rounds := coalesce((p_payload ->> 'rounds_required')::boolean, false);
    v_rounds_every := case when v_rounds then (p_payload ->> 'rounds_every_minutes')::int end;
    v_visitors := coalesce((p_payload ->> 'visitor_control')::boolean, false);
    v_assign_on := v_admin and coalesce((p_payload ->> 'assign_guards')::boolean, false);
  exception when others then
    raise exception 'servicios inválidos' using errcode = '22023';
  end;
  if v_rounds and (v_rounds_every is null or v_rounds_every not between 15 and 1440) then
    raise exception 'indica cada cuánto se hacen las rondas (entre 15 minutos y 24 horas)' using errcode = '22023';
  end if;
  if v_visitors and (v_new or not v_site.visitor_control) and not exists (
       select 1 from public.company_modules m
       where m.company_id = v_company and m.module = 'ingresos' and m.enabled) then
    raise exception 'el control de visitas es un módulo aparte: pide que lo activen para tu empresa' using errcode = '22023';
  end if;

  v_survey := coalesce(p_payload -> 'survey', '{}'::jsonb);
  if jsonb_typeof(v_survey) <> 'object' then
    raise exception 'levantamiento inválido' using errcode = '22023';
  end if;

  -- ---- Crear o actualizar el sitio ----
  if v_new then
    v_status := case when v_admin then 'approved' when p_submit then 'pending' else 'draft' end;
    insert into public.sites (company_id, client_id, name, lat, lng, radius_m, active, status, address,
                              proposed_by, submitted_at, approved_by, approved_at, proposed_client_name,
                              rounds_required, rounds_every_minutes, visitor_control,
                              survey, survey_at, survey_by)
    values (v_company, v_client, v_name, v_lat, v_lng, v_radius, v_status = 'approved', v_status,
            p_payload ->> 'address',
            case when v_admin then null else v_uid end,
            case when v_status = 'pending' then now() end,
            case when v_admin then v_uid end,
            case when v_admin then now() end,
            v_client_name, v_rounds, v_rounds_every, v_visitors,
            v_survey,
            case when v_survey <> '{}'::jsonb then now() end,
            case when v_survey <> '{}'::jsonb then v_uid end)
    returning id into v_id;
    if not v_admin then
      insert into public.supervisor_sites (supervisor_id, site_id, company_id) values (v_uid, v_id, v_company);
    end if;
  else
    v_id := p_site_id;
    update public.sites set
      client_id = v_client,
      name = v_name,
      lat = v_lat,
      lng = v_lng,
      radius_m = v_radius,
      address = p_payload ->> 'address',
      proposed_client_name = v_client_name,
      rounds_required = v_rounds,
      rounds_every_minutes = v_rounds_every,
      visitor_control = v_visitors,
      survey = v_survey,
      survey_at = case when v_survey is distinct from v_site.survey then now() else survey_at end,
      survey_by = case when v_survey is distinct from v_site.survey then v_uid else survey_by end,
      status = case when not v_admin and p_submit then 'pending' else status end,
      submitted_at = case when not v_admin and p_submit then now() else submitted_at end
    where id = v_id;
  end if;

  -- ---- Puestos, su inventario y sus guardas ----
  if jsonb_typeof(coalesce(p_payload -> 'posts', '[]'::jsonb)) <> 'array' then
    raise exception 'puestos inválidos' using errcode = '22023';
  end if;
  for p in select x from jsonb_array_elements(coalesce(p_payload -> 'posts', '[]'::jsonb)) as t(x) loop
    v_pname := private.norm_text(p ->> 'name');
    if v_pname is null then
      raise exception 'cada puesto necesita un nombre' using errcode = '22023';
    end if;
    begin
      v_from := coalesce((p ->> 'cover_from')::time, '06:00'::time);
      v_to := coalesce((p ->> 'cover_to')::time, v_from);
      v_hours := coalesce((p ->> 'shift_hours')::int, 12);
      v_req := coalesce((p ->> 'guards_required')::int, 1);
      v_days := case when jsonb_typeof(p -> 'days') = 'array'
                     then array(select (d)::smallint from jsonb_array_elements_text(p -> 'days') as e(d))
                     else '{1,2,3,4,5,6,7}'::smallint[] end;
    exception when others then
      raise exception 'el horario del puesto "%" no es válido', v_pname using errcode = '22023';
    end;
    if v_hours not between 1 and 24 then
      raise exception 'el turno del puesto "%" debe durar entre 1 y 24 horas', v_pname using errcode = '22023';
    end if;
    if v_req not between 0 and 50 then
      raise exception 'revisa los guardas requeridos del puesto "%"', v_pname using errcode = '22023';
    end if;
    if cardinality(v_days) = 0 or not (v_days <@ '{1,2,3,4,5,6,7}'::smallint[]) then
      raise exception 'elige los días del puesto "%"', v_pname using errcode = '22023';
    end if;
    v_orders := nullif(btrim(coalesce(p ->> 'orders', '')), '');
    if length(v_orders) > 4000 then
      raise exception 'las consignas del puesto "%" son demasiado largas', v_pname using errcode = '22023';
    end if;

    v_post_id := private.try_uuid(p ->> 'id');
    if v_post_id is not null then
      select * into v_post from public.site_posts where id = v_post_id and site_id = v_id for update;
      if not found then
        raise exception 'puesto inválido' using errcode = '22023';
      end if;
      update public.site_posts set
        name = v_pname, cover_from = v_from, cover_to = v_to, shift_hours = v_hours, days = v_days,
        guards_required = v_req, orders = v_orders,
        orders_updated_at = case when v_orders is distinct from v_post.orders then now() else orders_updated_at end,
        sort_order = v_sort, active = true
      where id = v_post_id;
    else
      insert into public.site_posts (company_id, site_id, name, cover_from, cover_to, shift_hours, days,
                                     guards_required, orders, orders_updated_at, sort_order)
      values (v_company, v_id, v_pname, v_from, v_to, v_hours, v_days, v_req, v_orders,
              case when v_orders is not null then now() end, v_sort)
      returning id into v_post_id;
    end if;
    v_keep_posts := v_keep_posts || v_post_id;
    v_sort := v_sort + 1;

    if jsonb_typeof(coalesce(p -> 'implements', '[]'::jsonb)) <> 'array' then
      raise exception 'implementos inválidos en el puesto "%"', v_pname using errcode = '22023';
    end if;
    for i in select x from jsonb_array_elements(coalesce(p -> 'implements', '[]'::jsonb)) as t(x) loop
      v_impl := private.try_uuid(i ->> 'id');
      select * into v_type from public.implement_types
       where id = private.try_uuid(i ->> 'type_id') and company_id = v_company;
      if not found or (v_impl is null and not v_type.active) then
        raise exception 'tipo de implemento inválido en el puesto "%"', v_pname using errcode = '22023';
      end if;
      begin
        v_qty := coalesce((i ->> 'quantity')::int, 1);
      exception when others then
        v_qty := 0;
      end;
      if v_qty not between 1 and 10000 then
        raise exception 'revisa la cantidad de % en el puesto "%"', v_type.name, v_pname using errcode = '22023';
      end if;
      if v_impl is not null then
        update public.site_implements set
          post_id = v_post_id, type_id = v_type.id, label = i ->> 'label', serial = i ->> 'serial',
          quantity = v_qty, active = true
        where id = v_impl and site_id = v_id;
        if not found then
          raise exception 'implemento inválido' using errcode = '22023';
        end if;
      else
        insert into public.site_implements (company_id, site_id, post_id, type_id, label, serial, quantity)
        values (v_company, v_id, v_post_id, v_type.id, i ->> 'label', i ->> 'serial', v_qty)
        returning id into v_impl;
      end if;
      v_keep_impl := v_keep_impl || v_impl;
    end loop;

    if v_assign_on and jsonb_typeof(p -> 'guards') = 'array' then
      for g in select x from jsonb_array_elements_text(p -> 'guards') as t(x) loop
        if private.try_uuid(g) is null or not exists (
             select 1 from public.profiles pr
             where pr.id = private.try_uuid(g) and pr.company_id = v_company and pr.role = 'guard' and pr.active) then
          raise exception 'guarda inválido' using errcode = '22023';
        end if;
        if v_assign ? g then
          raise exception 'un guarda solo puede tener un puesto por sitio' using errcode = '22023';
        end if;
        v_assign := v_assign || jsonb_build_object(g, v_post_id);
      end loop;
    end if;
  end loop;

  if cardinality(v_keep_posts) = 0 then
    raise exception 'el sitio necesita al menos un puesto' using errcode = '22023';
  end if;
  update public.site_posts set active = false
   where site_id = v_id and active and not (id = any (v_keep_posts));
  update public.site_implements set active = false
   where site_id = v_id and active and not (id = any (v_keep_impl));

  if v_assign_on then
    update public.guard_sites set active = false
     where site_id = v_id and active and not (v_assign ? guard_id::text);
    for g in select k from jsonb_object_keys(v_assign) as t(k) loop
      update public.guard_sites set active = true, post_id = (v_assign ->> g)::uuid
       where site_id = v_id and guard_id = g::uuid;
      if not found then
        insert into public.guard_sites (guard_id, site_id, company_id, active, post_id)
        values (g::uuid, v_id, v_company, true, (v_assign ->> g)::uuid);
      end if;
    end loop;
  end if;

  -- ---- Administradores y contactos del cliente ----
  if jsonb_typeof(coalesce(p_payload -> 'contacts', '[]'::jsonb)) <> 'array' then
    raise exception 'contactos inválidos' using errcode = '22023';
  end if;
  for c in select x from jsonb_array_elements(coalesce(p_payload -> 'contacts', '[]'::jsonb)) as t(x) loop
    v_contact := private.try_uuid(c ->> 'id');
    v_cname := private.norm_text(c ->> 'full_name');
    if v_cname is null then
      raise exception 'cada contacto necesita su nombre' using errcode = '22023';
    end if;
    begin
      v_trained := nullif(c ->> 'trained_at', '')::date;
    exception when others then
      raise exception 'la fecha de capacitación de % no es válida', v_cname using errcode = '22023';
    end;
    if v_trained > current_date then
      raise exception 'la fecha de capacitación no puede ser futura' using errcode = '22023';
    end if;
    if v_contact is not null then
      update public.site_contacts set
        full_name = v_cname,
        job_title = private.norm_text(c ->> 'job_title'),
        phone = private.norm_phone(c ->> 'phone'),
        email = private.norm_email(c ->> 'email'),
        is_admin = coalesce((c ->> 'is_admin')::boolean, false),
        trained_by = case when v_trained is distinct from trained_at
                          then case when v_trained is null then null else v_uid end
                          else trained_by end,
        trained_at = v_trained,
        active = true
      where id = v_contact and site_id = v_id;
      if not found then
        raise exception 'contacto inválido' using errcode = '22023';
      end if;
    else
      insert into public.site_contacts (company_id, site_id, full_name, job_title, phone, email, is_admin,
                                        trained_at, trained_by)
      values (v_company, v_id, v_cname, private.norm_text(c ->> 'job_title'), private.norm_phone(c ->> 'phone'),
              private.norm_email(c ->> 'email'), coalesce((c ->> 'is_admin')::boolean, false),
              v_trained, case when v_trained is not null then v_uid end)
      returning id into v_contact;
    end if;
    v_keep_contacts := v_keep_contacts || v_contact;
  end loop;
  update public.site_contacts set active = false
   where site_id = v_id and active and not (id = any (v_keep_contacts));

  return v_id;
end $$;

revoke execute on function public.save_site(uuid, jsonb, boolean) from public, anon;
grant execute on function public.save_site(uuid, jsonb, boolean) to authenticated;
