-- Módulo del guarda (5/5): relevo (entrega y recepción del puesto) e inventario del supervisor.
-- * El que sale marca cada implemento: bien / mal estado / falta (y cuenta la munición).
-- * El que entra marca lo mismo por su lado, SIN ver lo que declaró el otro ni las cantidades.
-- * El servidor compara: si no cuadra, alerta con el color del peor implemento (mínimo naranja).
-- * Un implemento ya reportado no vuelve a generar alerta en cada relevo.
-- * Puesto con arma y guarda sin licencia de portación vigente: alerta roja.
-- * Si el turno anterior recibió pero nunca entregó: alerta naranja "relevo sin entrega".
-- Nunca bloquea el turno: un sitio sin guarda es peor que un guarda con alerta.

create table public.post_handovers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  site_id uuid not null references public.sites(id) on delete cascade,
  post_id uuid not null references public.site_posts(id) on delete cascade,
  kind text not null check (kind in ('delivery', 'reception', 'inventory')),
  actor_id uuid references public.profiles(id) on delete set null,
  shift_id uuid references public.shifts(id) on delete set null,
  device_id uuid references public.devices(id) on delete set null,
  compared_to uuid references public.post_handovers(id) on delete set null,
  orders_seen_at timestamptz,      -- versión de las consignas que aceptó
  result text not null default 'ok' check (result in ('ok', 'issues', 'mismatch')),
  severity text check (severity in ('red', 'orange', 'yellow')),
  note text,
  lat double precision,
  lng double precision,
  created_at timestamptz not null default now()
);
create index post_handovers_post_idx on public.post_handovers (post_id, created_at desc);
create index post_handovers_actor_idx on public.post_handovers (actor_id, created_at desc);
create index post_handovers_company_idx on public.post_handovers (company_id, created_at desc);

create table public.post_handover_items (
  handover_id uuid not null references public.post_handovers(id) on delete cascade,
  implement_id uuid not null references public.site_implements(id) on delete cascade,
  status text not null check (status in ('ok', 'damaged', 'missing')),
  counted integer check (counted between 0 and 10000),
  note text,
  photo_path text,
  expected_status text,            -- lo que declaró el acta anterior (solo en recepción)
  expected_count integer,
  primary key (handover_id, implement_id)
);

alter table public.post_handovers enable row level security;
alter table public.post_handover_items enable row level security;
create policy post_handovers_select on public.post_handovers for select to authenticated
  using (private.is_admin_of(company_id)
         or (private.user_role() = 'supervisor' and private.sees_site(site_id))
         or (actor_id = (select auth.uid()) and private.user_role() is not null));
create policy post_handover_items_select on public.post_handover_items for select to authenticated
  using (exists (select 1 from public.post_handovers h where h.id = handover_id));
revoke all on public.post_handovers from anon;
revoke all on public.post_handover_items from anon;
revoke insert, update, delete, truncate, references, trigger on public.post_handovers from authenticated;
revoke insert, update, delete, truncate, references, trigger on public.post_handover_items from authenticated;

-- ---------- Lista para el relevo (a ciegas: sin cantidades ni último estado) ----------
create or replace function public.post_checklist(p_post_id uuid)
returns table (implement_id uuid, type_name text, category text, tracking text, label text,
               serial text, needs_weapon_license boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_site uuid;
begin
  select p.site_id into v_site from public.site_posts p where p.id = p_post_id and p.active;
  if v_site is null or not private.sees_site(v_site)
     or coalesce(private.user_role()::text, '') not in ('super_admin', 'company_admin', 'supervisor', 'guard') then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  return query
    select si.id, t.name, t.category, t.tracking, si.label, si.serial, t.needs_weapon_license
    from public.site_implements si
    join public.implement_types t on t.id = si.type_id
    where si.post_id = p_post_id and si.active
    order by t.sort_order, t.name, si.label;
end $$;

-- ---------- Registrar entrega, recepción o inventario ----------
create or replace function public.submit_handover(
  p_post_id uuid,
  p_kind text,
  p_items jsonb,
  p_note text default null,
  p_device_id uuid default null,
  p_shift_id uuid default null,
  p_orders_seen boolean default false,
  p_lat double precision default null,
  p_lng double precision default null)
returns table (r_id uuid, r_result text, r_severity text, r_detail text)
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_role public.app_role := private.user_role();
  v_post public.site_posts%rowtype;
  v_site public.sites%rowtype;
  v_prev public.post_handovers%rowtype;
  v_compare uuid;
  v_related uuid;
  v_no_delivery boolean := false;
  v_id uuid;
  v_expected int;
  v_given int;
  rec record;
  v_status text;
  v_counted int;
  v_note text;
  v_exp_status text;
  v_exp_count int;
  v_base int;
  v_worse boolean;
  v_diff boolean;
  v_item_sev text;
  v_sev text;
  v_mismatch boolean := false;
  v_issues boolean := false;
  v_weapon boolean := false;
  v_license boolean;
  v_lines text[] := '{}';
  v_desc text;
  v_title text;
  v_result text;
begin
  if p_kind is null or p_kind not in ('delivery', 'reception', 'inventory') then
    raise exception 'tipo de acta inválido' using errcode = '22023';
  end if;
  -- Un acta a la vez por puesto.
  select * into v_post from public.site_posts where id = p_post_id and active for update;
  if not found then
    raise exception 'puesto no encontrado' using errcode = '42501';
  end if;
  select * into v_site from public.sites where id = v_post.site_id;

  if p_kind in ('delivery', 'reception') then
    if v_role is distinct from 'guard' or not v_site.active or not exists (
         select 1 from public.guard_sites gs
         where gs.site_id = v_site.id and gs.guard_id = v_uid and gs.active) then
      raise exception 'guarda no asignado a este sitio' using errcode = '42501';
    end if;
  elsif not coalesce(private.is_admin_of(v_site.company_id)
                     or (v_role = 'supervisor' and private.sees_site(v_site.id)), false) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  if p_device_id is not null and not exists (
       select 1 from public.devices d where d.id = p_device_id and d.site_id = v_site.id and d.active) then
    raise exception 'teléfono no vinculado a este sitio' using errcode = '42501';
  end if;
  if p_shift_id is not null and not exists (
       select 1 from public.shifts s where s.id = p_shift_id and s.site_id = v_site.id and s.guard_id = v_uid) then
    raise exception 'turno inválido' using errcode = '22023';
  end if;

  -- Cada implemento activo del puesto debe venir exactamente una vez.
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'lista de implementos inválida' using errcode = '22023';
  end if;
  select count(*) into v_expected from public.site_implements where post_id = p_post_id and active;
  select count(distinct si.id) into v_given
    from jsonb_array_elements(p_items) as x(item)
    join public.site_implements si
      on si.id = private.try_uuid(x.item ->> 'implement_id') and si.post_id = p_post_id and si.active;
  if v_given <> v_expected or jsonb_array_length(p_items) <> v_expected then
    raise exception 'la lista de implementos está incompleta o no corresponde al puesto' using errcode = '22023';
  end if;

  -- ¿Contra qué se compara una recepción?
  select * into v_prev from public.post_handovers
   where post_id = p_post_id order by created_at desc, id desc limit 1;
  if found and p_kind = 'reception' then
    if v_prev.kind = 'reception' and v_prev.actor_id = v_uid then
      null;                               -- vuelve a recibir el mismo guarda: solo cuenta lo que empeoró
    elsif v_prev.kind = 'reception' then
      v_no_delivery := true;              -- el turno anterior recibió y nunca entregó
      v_related := v_prev.actor_id;
    else
      v_compare := v_prev.id;             -- entrega (o inventario) más reciente
      v_related := v_prev.actor_id;
    end if;
  end if;

  perform set_config('app.in_handover', 'on', true);

  insert into public.post_handovers (company_id, site_id, post_id, kind, actor_id, shift_id, device_id,
                                     compared_to, orders_seen_at, note, lat, lng, created_at)
  values (v_site.company_id, v_site.id, p_post_id, p_kind, v_uid, p_shift_id, p_device_id, v_compare,
          case when p_orders_seen then coalesce(v_post.orders_updated_at, now()) end,
          left(private.norm_text(p_note), 1000), p_lat, p_lng, clock_timestamp())
  returning id into v_id;

  for rec in
    select si.id, si.status as cur_status, si.quantity, si.last_counted, si.label, si.serial,
           t.name as type_name, t.severity as type_sev, t.tracking, t.needs_weapon_license,
           x.item
    from public.site_implements si
    join public.implement_types t on t.id = si.type_id
    join jsonb_array_elements(p_items) as x(item) on private.try_uuid(x.item ->> 'implement_id') = si.id
    where si.post_id = p_post_id and si.active
    order by t.sort_order, t.name, si.label
  loop
    v_status := rec.item ->> 'status';
    if v_status is null or v_status not in ('ok', 'damaged', 'missing') then
      raise exception 'marca el estado de %', rec.type_name using errcode = '22023';
    end if;
    v_counted := null;
    if rec.tracking = 'count' then
      begin
        v_counted := (rec.item ->> 'counted')::int;
      exception when others then
        v_counted := null;
      end;
      if v_counted is null or v_counted not between 0 and 10000 then
        raise exception 'escribe cuántas unidades de % hay', rec.type_name using errcode = '22023';
      end if;
      if v_counted < rec.quantity then
        v_status := 'missing';          -- faltan unidades
      end if;
    end if;
    v_note := left(private.norm_text(rec.item ->> 'note'), 300);

    v_exp_status := null;
    v_exp_count := null;
    if v_compare is not null then
      select hi.status, hi.counted into v_exp_status, v_exp_count
        from public.post_handover_items hi
       where hi.handover_id = v_compare and hi.implement_id = rec.id;
    end if;

    insert into public.post_handover_items (handover_id, implement_id, status, counted, note,
                                            expected_status, expected_count)
    values (v_id, rec.id, v_status, v_counted, v_note, v_exp_status, v_exp_count);

    -- ¿Empeoró respecto a lo último que se sabía?
    v_base := least(coalesce(rec.last_counted, rec.quantity), rec.quantity);
    v_worse := private.status_rank(v_status) > private.status_rank(rec.cur_status)
               or (rec.tracking = 'count' and v_counted < v_base);
    -- ¿No cuadra con la entrega?
    v_diff := v_exp_status is not null and (
                private.status_rank(v_status) > private.status_rank(v_exp_status)
                or (rec.tracking = 'count' and v_exp_count is not null and v_counted < v_exp_count));

    v_item_sev := null;
    if v_worse then
      v_item_sev := case when v_status = 'missing' then rec.type_sev else private.sev_down(rec.type_sev) end;
    end if;
    if v_diff then
      v_mismatch := true;
      v_item_sev := private.sev_max(v_item_sev, 'orange');
      if v_status = 'missing' then
        v_item_sev := private.sev_max(v_item_sev, rec.type_sev);
      end if;
    end if;
    if v_status <> 'ok' then
      v_issues := true;
    end if;
    -- Recibe arma o munición (aunque sea incompleta).
    if rec.needs_weapon_license and (v_status <> 'missing' or coalesce(v_counted, 0) > 0) then
      v_weapon := true;
    end if;

    if v_item_sev is not null then
      v_sev := private.sev_max(v_sev, v_item_sev);
      v_desc := rec.type_name || coalesce(' ' || rec.label, '') || coalesce(' (serie ' || rec.serial || ')', '');
      v_lines := v_lines || (
        v_desc || ': '
        || case v_status when 'missing' then 'falta' when 'damaged' then 'mal estado' else 'bien' end
        || case when rec.tracking = 'count' then ' (' || v_counted || ' de ' || rec.quantity || ')' else '' end
        || case when v_diff then ' · la entrega decía '
                  || case v_exp_status when 'missing' then 'falta' when 'damaged' then 'mal estado' else 'bien' end
                  || case when v_exp_count is not null then ' (' || v_exp_count || ')' else '' end
                else '' end
        || coalesce(' — ' || v_note, ''));
    end if;

    update public.site_implements
       set status = v_status, status_note = v_note, status_at = now(),
           last_counted = coalesce(v_counted, last_counted)
     where id = rec.id
       and (status is distinct from v_status or status_note is distinct from v_note
            or (v_counted is not null and last_counted is distinct from v_counted));
  end loop;

  if v_no_delivery then
    v_sev := private.sev_max(v_sev, 'orange');
    v_lines := array_prepend('El turno anterior no entregó el puesto', v_lines);
  end if;
  if p_kind = 'reception' and v_weapon then
    select exists (
      select 1 from public.documents d
      join public.document_types t on t.id = d.type_id
      where d.profile_id = v_uid and t.key = 'weapon_license' and d.expires_on >= current_date)
    into v_license;
    if not v_license then
      v_sev := 'red';
      v_lines := array_prepend('Recibió un arma sin licencia de portación vigente', v_lines);
    end if;
  end if;

  v_result := case when v_mismatch then 'mismatch' when v_issues then 'issues' else 'ok' end;
  update public.post_handovers set result = v_result, severity = v_sev where id = v_id;

  if v_sev is not null then
    v_title := case
      when v_license is false then 'Arma sin licencia vigente'
      when v_mismatch then 'El relevo no cuadra'
      when v_no_delivery then 'Relevo sin entrega'
      when p_kind = 'delivery' then 'Entrega con novedades'
      when p_kind = 'inventory' then 'Inventario con novedades'
      else 'Recepción con novedades' end;
    insert into public.alerts (company_id, site_id, post_id, guard_id, related_guard_id, source, source_id,
                               severity, title, detail)
    values (v_site.company_id, v_site.id, p_post_id, case when v_role = 'guard' then v_uid end, v_related,
            'handover', v_id, v_sev, v_title || ' · ' || v_post.name, array_to_string(v_lines, E'\n'));
  end if;

  perform set_config('app.in_handover', 'off', true);
  return query select v_id, v_result, v_sev, nullif(array_to_string(v_lines, E'\n'), '');
end $$;

revoke execute on function public.post_checklist(uuid) from public, anon;
revoke execute on function public.submit_handover(uuid, text, jsonb, text, uuid, uuid, boolean, double precision, double precision) from public, anon;
grant execute on function public.post_checklist(uuid) to authenticated;
grant execute on function public.submit_handover(uuid, text, jsonb, text, uuid, uuid, boolean, double precision, double precision) to authenticated;
