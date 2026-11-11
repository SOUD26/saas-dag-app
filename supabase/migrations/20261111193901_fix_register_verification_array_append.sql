-- Corrección: concatenar texto a un arreglo con array_append (la versión anterior fallaba con textos literales).
create or replace function public.register_verification(
  p_site_id uuid, p_device_id uuid, p_kind text, p_method text,
  p_face_score real, p_matched_guard_id uuid,
  p_lat double precision, p_lng double precision,
  p_fallback_reason text, p_photo_path text)
returns table (r_id uuid, r_within boolean, r_flagged boolean, r_reason text)
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_site public.sites%rowtype;
  v_dist double precision;
  v_within boolean;
  v_reasons text[] := '{}';
  v_id uuid;
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
    v_reasons := array_append(v_reasons, 'sin cara: ' || coalesce(nullif(trim(p_fallback_reason), ''), 'sin motivo'));
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
