-- Módulo del guarda (6): turno sin señal y contexto del guarda.
-- * Todo lo que registra el guarda puede llegar tarde (sin señal): cada registro trae un id creado en el
--   teléfono (si llega dos veces, no se duplica) y la hora del teléfono (happened_at). Si llega más de
--   5 minutos después, queda marcado "sin conexión" (offline). La hora del teléfono se puede manipular:
--   nunca se acepta una hora futura y el administrador ve la marca.
-- * Mientras la empresa no exija cara (companies.face_required = false, hasta que exista el módulo de
--   reconocimiento facial), entrar con contraseña + GPS NO es alerta: si lo fuera, todos los guardas
--   serían "reincidentes" desde el primer día. Las alertas de GPS siguen igual.
-- * guard_context(): todo lo que el teléfono del guarda necesita guardar para trabajar sin señal.

alter table public.companies add column if not exists face_required boolean not null default false;

alter table public.shift_verifications
  add column if not exists client_id uuid,
  add column if not exists happened_at timestamptz,
  add column if not exists offline boolean not null default false;
create unique index if not exists shift_verifications_client_uq on public.shift_verifications (client_id);

alter table public.post_handovers
  add column if not exists client_id uuid,
  add column if not exists happened_at timestamptz,
  add column if not exists offline boolean not null default false;
create unique index if not exists post_handovers_client_uq on public.post_handovers (client_id);

-- Hora del teléfono: nunca en el futuro (2 min de tolerancia) ni de hace más de 30 días.
create or replace function private.device_time(p timestamptz) returns timestamptz
language sql stable set search_path = '' as $$
  select case
    when p is null or p > now() + interval '2 minutes' then now()
    when p < now() - interval '30 days' then now() - interval '30 days'
    else p end
$$;

create or replace function private.is_offline(p timestamptz) returns boolean
language sql stable set search_path = '' as $$
  select p is not null and p < now() - interval '5 minutes'
$$;

-- ---------- Verificación: sin alerta por "sin cara" mientras la empresa no exija cara ----------
create or replace function public.register_verification(
  p_site_id uuid, p_device_id uuid, p_kind text, p_method text, p_face_score real, p_matched_guard_id uuid,
  p_lat double precision, p_lng double precision, p_fallback_reason text, p_photo_path text)
returns table (r_id uuid, r_within boolean, r_flagged boolean, r_reason text)
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_site public.sites%rowtype;
  v_dist double precision;
  v_within boolean;
  v_reasons text[] := '{}';
  v_id uuid;
  v_face_required boolean;
begin
  if private.user_role() is distinct from 'guard' then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  select s.* into v_site
  from public.sites s
  join public.guard_sites gs on gs.site_id = s.id
  where s.id = p_site_id and s.active and gs.guard_id = v_uid and gs.active;
  if not found then
    raise exception 'guarda no asignado a este sitio' using errcode = '42501';
  end if;
  if p_kind not in ('shift_start','random_check')
     or p_method not in ('face','password_fallback','face_rejected') then
    raise exception 'parámetros inválidos' using errcode = '22023';
  end if;
  if p_device_id is not null and not exists (
       select 1 from public.devices d where d.id = p_device_id and d.site_id = p_site_id and d.active) then
    raise exception 'teléfono no vinculado a este sitio' using errcode = '42501';
  end if;
  if p_photo_path is not null and p_photo_path not like (v_site.company_id::text || '/%') then
    raise exception 'ruta de foto inválida' using errcode = '22023';
  end if;
  select c.face_required into v_face_required from public.companies c where c.id = v_site.company_id;

  if p_lat is null or p_lng is null then
    v_within := false;
    v_reasons := array_append(v_reasons, 'sin GPS');
  else
    v_dist := 6371000 * 2 * asin(least(1, sqrt(
        power(sin(radians(p_lat - v_site.lat) / 2), 2)
        + cos(radians(v_site.lat)) * cos(radians(p_lat)) * power(sin(radians(p_lng - v_site.lng) / 2), 2))));
    v_within := v_dist <= v_site.radius_m;
    if not v_within then
      v_reasons := array_append(v_reasons, 'fuera del perímetro (' || round(v_dist)::text || ' m)');
    end if;
  end if;

  if p_method = 'password_fallback' then
    if coalesce(v_face_required, false) then
      v_reasons := array_append(v_reasons, 'sin cara: ' || coalesce(nullif(trim(p_fallback_reason), ''), 'sin motivo'));
    end if;
  elsif p_method = 'face_rejected' then
    v_reasons := array_append(v_reasons, 'cara no reconocida (posible intruso)');
  elsif p_matched_guard_id is distinct from v_uid then
    v_reasons := array_append(v_reasons, 'la cara no coincide con el usuario');
  end if;

  insert into public.shift_verifications
    (company_id, guard_id, site_id, device_id, kind, method, face_score, matched_guard_id,
     lat, lng, distance_m, within_perimeter, flagged, flag_reason, photo_path)
  values
    (v_site.company_id, v_uid, p_site_id, p_device_id, p_kind, p_method, p_face_score, p_matched_guard_id,
     p_lat, p_lng, v_dist::real, v_within, cardinality(v_reasons) > 0, nullif(array_to_string(v_reasons, '; '), ''), p_photo_path)
  returning id into v_id;

  return query select v_id, v_within, cardinality(v_reasons) > 0, nullif(array_to_string(v_reasons, '; '), '');
end $$;

-- Versión que usa el teléfono del guarda: no se duplica y guarda la hora real del teléfono.
create or replace function public.record_verification(
  p_client_id uuid, p_site_id uuid, p_device_id uuid, p_kind text, p_method text, p_face_score real,
  p_matched_guard_id uuid, p_lat double precision, p_lng double precision, p_fallback_reason text,
  p_photo_path text, p_happened_at timestamptz default null)
returns table (r_id uuid, r_within boolean, r_flagged boolean, r_reason text)
language plpgsql security definer set search_path = '' as $$
declare
  v public.shift_verifications%rowtype;
  rec record;
begin
  if p_client_id is not null then
    select * into v from public.shift_verifications where client_id = p_client_id;
    if found then
      if v.guard_id is distinct from (select auth.uid()) then
        raise exception 'no autorizado' using errcode = '42501';
      end if;
      return query select v.id, v.within_perimeter, v.flagged, v.flag_reason;
      return;
    end if;
  end if;
  select * into rec from public.register_verification(p_site_id, p_device_id, p_kind, p_method, p_face_score,
                                                     p_matched_guard_id, p_lat, p_lng, p_fallback_reason, p_photo_path);
  update public.shift_verifications
     set client_id = p_client_id, happened_at = private.device_time(p_happened_at), offline = private.is_offline(p_happened_at)
   where id = rec.r_id;
  return query select rec.r_id, rec.r_within, rec.r_flagged, rec.r_reason;
end $$;

-- La llegada del turno usa la hora del teléfono cuando el registro llegó sin señal.
create or replace view public.shift_log with (security_invoker = true) as
 select s.id as shift_id,
    s.company_id,
    s.site_id,
    s.guard_id,
    s.starts_at,
    s.ends_at,
    s.grace_minutes,
    s.cancelled,
    s.notes,
    v.arrived_at,
        case
            when v.arrived_at is null then null::integer
            else greatest(0::numeric, ceil(extract(epoch from v.arrived_at - s.starts_at) / 60::numeric))::integer
        end as late_minutes,
    coalesce(v.checks, 0::bigint) as checks,
    coalesce(v.flags, 0::bigint) as flags,
        case
            when s.cancelled then 'cancelado'::text
            when v.arrived_at is not null and v.arrived_at <= (s.starts_at + make_interval(mins => s.grace_minutes)) then 'a_tiempo'::text
            when v.arrived_at is not null then 'tarde'::text
            when now() < s.starts_at then 'programado'::text
            when now() <= (s.starts_at + make_interval(mins => s.grace_minutes)) then 'por_iniciar'::text
            when now() <= s.ends_at then 'sin_llegada'::text
            else 'ausente'::text
        end as status
   from public.shifts s
     left join lateral ( select min(coalesce(sv.happened_at, sv.created_at)) filter (where sv.kind = 'shift_start'::text) as arrived_at,
            count(*) as checks,
            count(*) filter (where sv.flagged) as flags
           from public.shift_verifications sv
          where sv.guard_id = s.guard_id and sv.site_id = s.site_id
            and coalesce(sv.happened_at, sv.created_at) >= (s.starts_at - '02:00:00'::interval)
            and coalesce(sv.happened_at, sv.created_at) <= s.ends_at) v on true;

-- ---------- Relevo desde el teléfono: no se duplica y guarda la hora real ----------
create or replace function public.record_handover(
  p_client_id uuid,
  p_post_id uuid,
  p_kind text,
  p_items jsonb,
  p_note text default null,
  p_device_id uuid default null,
  p_shift_id uuid default null,
  p_orders_seen boolean default false,
  p_lat double precision default null,
  p_lng double precision default null,
  p_happened_at timestamptz default null)
returns table (r_id uuid, r_result text, r_severity text, r_detail text)
language plpgsql security definer set search_path = '' as $$
declare
  h public.post_handovers%rowtype;
  rec record;
begin
  if p_client_id is not null then
    select * into h from public.post_handovers where client_id = p_client_id;
    if found then
      if h.actor_id is distinct from (select auth.uid()) then
        raise exception 'no autorizado' using errcode = '42501';
      end if;
      return query select h.id, h.result, h.severity,
        (select a.detail from public.alerts a where a.source = 'handover' and a.source_id = h.id);
      return;
    end if;
  end if;
  select * into rec from public.submit_handover(p_post_id, p_kind, p_items, p_note, p_device_id, p_shift_id,
                                               p_orders_seen, p_lat, p_lng);
  update public.post_handovers
     set client_id = p_client_id, happened_at = private.device_time(p_happened_at), offline = private.is_offline(p_happened_at)
   where id = rec.r_id;
  return query select rec.r_id, rec.r_result, rec.r_severity, rec.r_detail;
end $$;

-- ---------- Fotos de perfil: el guarda ve a su supervisor y a sus compañeros del sitio ----------
-- (Esta función la usa SOLO la política de fotos de perfil "avatars: ver".)
create or replace function private.can_view_person(p_profile uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select (t.id = (select auth.uid()) and private.user_role() is not null)
        or private.is_admin_of(t.company_id)
        or private.supervises_guard(t.id)
        or (private.user_role() = 'guard' and exists (
              select 1 from public.guard_sites me
              where me.guard_id = (select auth.uid()) and me.active
                and (exists (select 1 from public.supervisor_sites ss
                             where ss.site_id = me.site_id and ss.supervisor_id = t.id)
                     or exists (select 1 from public.guard_sites o
                                where o.site_id = me.site_id and o.guard_id = t.id and o.active))))
    from public.profiles t where t.id = p_profile), false)
$$;

-- ---------- Todo lo que el teléfono del guarda guarda para trabajar sin señal ----------
create or replace function public.guard_context()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_me public.profiles%rowtype;
begin
  select * into v_me from public.profiles where id = v_uid and active and role = 'guard';
  if not found then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'server_time', now(),
    'guard', jsonb_build_object('id', v_me.id, 'name', v_me.full_name, 'phone', v_me.phone,
                                'avatar_path', v_me.avatar_path),
    'company', (select jsonb_build_object('id', c.id, 'name', c.name, 'code', c.code,
                                          'face_required', c.face_required)
                from public.companies c where c.id = v_me.company_id),
    'sites', coalesce((
      select jsonb_agg(jsonb_build_object(
        'site_id', s.id, 'name', s.name, 'address', s.address,
        'lat', s.lat, 'lng', s.lng, 'radius_m', s.radius_m,
        'visitor_control', s.visitor_control, 'rounds_required', s.rounds_required,
        'my_post_id', gs.post_id,
        'posts', (select coalesce(jsonb_agg(jsonb_build_object(
                     'id', p.id, 'name', p.name, 'orders', p.orders, 'orders_updated_at', p.orders_updated_at,
                     'cover_from', p.cover_from, 'cover_to', p.cover_to, 'shift_hours', p.shift_hours,
                     'last', (select jsonb_build_object('kind', h.kind, 'actor_id', h.actor_id,
                                                        'actor_name', a.full_name, 'at', h.created_at)
                              from public.post_handovers h
                              left join public.profiles a on a.id = h.actor_id
                              where h.post_id = p.id
                              order by h.created_at desc, h.id desc limit 1))
                   order by p.sort_order), '[]'::jsonb)
                  from public.site_posts p where p.site_id = s.id and p.active),
        'supervisors', (select coalesce(jsonb_agg(jsonb_build_object(
                           'id', sp.id, 'name', sp.full_name, 'phone', sp.phone, 'avatar_path', sp.avatar_path)
                         order by sp.full_name), '[]'::jsonb)
                        from public.supervisor_sites ss
                        join public.profiles sp on sp.id = ss.supervisor_id and sp.active and sp.role = 'supervisor'
                        where ss.site_id = s.id))
        order by s.name)
      from public.guard_sites gs
      join public.sites s on s.id = gs.site_id and s.active
      where gs.guard_id = v_uid and gs.active), '[]'::jsonb),
    'shifts', coalesce((
      select jsonb_agg(jsonb_build_object('id', sh.id, 'site_id', sh.site_id, 'post_id', sh.post_id,
                                          'starts_at', sh.starts_at, 'ends_at', sh.ends_at)
                       order by sh.starts_at)
      from public.shifts sh
      where sh.guard_id = v_uid and not sh.cancelled
        and sh.ends_at > now() - interval '12 hours' and sh.starts_at < now() + interval '36 hours'), '[]'::jsonb),
    'docs', coalesce((
      select jsonb_agg(jsonb_build_object('name', d.type_name, 'expires_on', d.expires_on,
                                          'status', d.status, 'days_left', d.days_left))
      from public.document_alerts(v_me.company_id, 30) d
      where d.owner_id = v_uid), '[]'::jsonb)
  );
end $$;

revoke execute on function public.record_verification(uuid, uuid, uuid, text, text, real, uuid, double precision, double precision, text, text, timestamptz) from public, anon;
revoke execute on function public.record_handover(uuid, uuid, text, jsonb, text, uuid, uuid, boolean, double precision, double precision, timestamptz) from public, anon;
revoke execute on function public.guard_context() from public, anon;
grant execute on function public.record_verification(uuid, uuid, uuid, text, text, real, uuid, double precision, double precision, text, text, timestamptz) to authenticated;
grant execute on function public.record_handover(uuid, uuid, text, jsonb, text, uuid, uuid, boolean, double precision, double precision, timestamptz) to authenticated;
grant execute on function public.guard_context() to authenticated;
