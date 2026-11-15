-- Módulo del guarda (4/5): una sola bandeja de alertas con tres niveles para toda la app.
--   red    = actuar ya        (posible intruso, la cara no coincide, arma faltante, arma sin licencia)
--   orange = revisar hoy      (entró sin cara, sin GPS, lejos del perímetro, relevo que no cuadra)
--   yellow = revisar después  (implemento menor, GPS apenas fuera del perímetro)
-- Si todo es rojo, nada es rojo. Las verificaciones existentes entran solas a la bandeja
-- (disparador) y su revisión se mantiene sincronizada en los dos lados.

create table public.alerts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  site_id uuid references public.sites(id) on delete cascade,
  post_id uuid references public.site_posts(id) on delete set null,
  guard_id uuid references public.profiles(id) on delete set null,
  related_guard_id uuid references public.profiles(id) on delete set null,
  source text not null check (source in ('verification', 'handover', 'round', 'panic', 'document', 'other')),
  source_id uuid,
  severity text not null check (severity in ('red', 'orange', 'yellow')),
  title text not null,
  detail text,
  created_at timestamptz not null default now(),
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  review_outcome text check (review_outcome in ('justified', 'false_alarm', 'action_required')),
  review_note text,
  constraint alerts_review_ck check ((reviewed_at is null) = (review_outcome is null)),
  constraint alerts_source_uq unique (source, source_id)
);
create index alerts_company_idx on public.alerts (company_id, created_at desc);
create index alerts_pending_idx on public.alerts (company_id, severity) where reviewed_at is null;
create index alerts_site_idx on public.alerts (site_id, created_at desc);
create index alerts_guard_idx on public.alerts (guard_id, created_at desc);

alter table public.alerts enable row level security;
create policy alerts_select on public.alerts for select to authenticated
  using (private.is_admin_of(company_id)
         or (private.user_role() = 'supervisor' and site_id is not null and private.sees_site(site_id)));
-- Solo las funciones del servidor crean y revisan alertas.
revoke all on public.alerts from anon;
revoke insert, update, delete, truncate, references, trigger on public.alerts from authenticated;

-- Nivel de una verificación según sus motivos (el más grave manda).
-- "Fuera del perímetro" hasta 1.5 veces el radio suele ser error de GPS: amarilla.
create or replace function private.verification_severity(
  p_method text, p_reason text, p_distance real, p_radius int)
returns text
language sql immutable set search_path = '' as $$
  select case
    when p_reason is null then null
    when p_method = 'face_rejected' or p_reason like '%posible intruso%' or p_reason like '%no coincide%' then 'red'
    when p_reason like '%sin cara%' or p_reason like '%sin GPS%' then 'orange'
    when p_reason like '%fuera del perímetro%' and p_distance is not null and p_radius is not null
         and p_distance <= p_radius * 1.5 then 'yellow'
    else 'orange'
  end
$$;

create or replace function private.verification_alert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_radius int;
begin
  if not new.flagged then
    return null;
  end if;
  select s.radius_m into v_radius from public.sites s where s.id = new.site_id;
  insert into public.alerts (company_id, site_id, guard_id, source, source_id, severity, title, detail,
                             created_at, reviewed_by, reviewed_at, review_outcome)
  values (new.company_id, new.site_id, new.guard_id, 'verification', new.id,
          private.verification_severity(new.method, new.flag_reason, new.distance_m, v_radius),
          case new.kind when 'shift_start' then 'Inicio de turno' else 'Re-verificación' end,
          new.flag_reason, new.created_at, new.reviewed_by, new.reviewed_at, new.review_outcome);
  return null;
end $$;

create trigger trg_verification_alert after insert on public.shift_verifications
  for each row execute function private.verification_alert();

-- Las alertas de verificación que ya existían.
insert into public.alerts (company_id, site_id, guard_id, source, source_id, severity, title, detail,
                           created_at, reviewed_by, reviewed_at, review_outcome)
select v.company_id, v.site_id, v.guard_id, 'verification', v.id,
       private.verification_severity(v.method, v.flag_reason, v.distance_m, s.radius_m),
       case v.kind when 'shift_start' then 'Inicio de turno' else 'Re-verificación' end,
       v.flag_reason, v.created_at, v.reviewed_by, v.reviewed_at, v.review_outcome
from public.shift_verifications v
join public.sites s on s.id = v.site_id
where v.flagged
  and not exists (select 1 from public.alerts a where a.source = 'verification' and a.source_id = v.id);

-- ---------- Revisar y reabrir (solo el administrador de la empresa) ----------
create or replace function public.review_alert(p_id uuid, p_outcome text, p_note text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  a public.alerts%rowtype;
begin
  if p_outcome is null or p_outcome not in ('justified', 'false_alarm', 'action_required') then
    raise exception 'resultado inválido' using errcode = '22023';
  end if;
  select * into a from public.alerts where id = p_id for update;
  if not found or not private.is_admin_of(a.company_id) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  update public.alerts
     set reviewed_by = (select auth.uid()), reviewed_at = now(), review_outcome = p_outcome,
         review_note = private.norm_text(p_note)
   where id = p_id;
  if a.source = 'verification' then
    update public.shift_verifications
       set reviewed_by = (select auth.uid()), reviewed_at = now(), review_outcome = p_outcome
     where id = a.source_id;
  end if;
  insert into public.audit_log (company_id, actor, action, target_user, detail)
  values (a.company_id, (select auth.uid()), 'alert_reviewed', a.guard_id,
          p_outcome || ' · ' || a.source || ' · ' || p_id::text);
end $$;

create or replace function public.reopen_alert(p_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  a public.alerts%rowtype;
begin
  select * into a from public.alerts where id = p_id for update;
  if not found or not private.is_admin_of(a.company_id) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  update public.alerts
     set reviewed_by = null, reviewed_at = null, review_outcome = null, review_note = null
   where id = p_id;
  if a.source = 'verification' then
    update public.shift_verifications
       set reviewed_by = null, reviewed_at = null, review_outcome = null
     where id = a.source_id;
  end if;
  insert into public.audit_log (company_id, actor, action, target_user, detail)
  values (a.company_id, (select auth.uid()), 'alert_reopened', a.guard_id, a.source || ' · ' || p_id::text);
end $$;

-- Las funciones anteriores (versiones viejas de la app) también mantienen la bandeja al día.
create or replace function public.review_verification(p_id uuid, p_outcome text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v public.shift_verifications%rowtype;
begin
  if p_outcome is null or p_outcome not in ('justified', 'false_alarm', 'action_required') then
    raise exception 'resultado inválido' using errcode = '22023';
  end if;
  select * into v from public.shift_verifications where id = p_id;
  if not found or not private.is_admin_of(v.company_id) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  if not v.flagged then
    raise exception 'esta verificación no tiene bandera' using errcode = '22023';
  end if;
  update public.shift_verifications
     set reviewed_by = (select auth.uid()), reviewed_at = now(), review_outcome = p_outcome
   where id = p_id;
  update public.alerts
     set reviewed_by = (select auth.uid()), reviewed_at = now(), review_outcome = p_outcome
   where source = 'verification' and source_id = p_id;
  insert into public.audit_log (company_id, actor, action, target_user, detail)
  values (v.company_id, (select auth.uid()), 'verification_reviewed', v.guard_id, p_outcome || ' · ' || p_id::text);
end $$;

create or replace function public.reopen_verification(p_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v public.shift_verifications%rowtype;
begin
  select * into v from public.shift_verifications where id = p_id;
  if not found or not private.is_admin_of(v.company_id) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  update public.shift_verifications
     set reviewed_by = null, reviewed_at = null, review_outcome = null
   where id = p_id;
  update public.alerts
     set reviewed_by = null, reviewed_at = null, review_outcome = null, review_note = null
   where source = 'verification' and source_id = p_id;
  insert into public.audit_log (company_id, actor, action, target_user, detail)
  values (v.company_id, (select auth.uid()), 'verification_reopened', v.guard_id, p_id::text);
end $$;

revoke execute on function public.review_alert(uuid, text, text) from public, anon;
revoke execute on function public.reopen_alert(uuid) from public, anon;
grant execute on function public.review_alert(uuid, text, text) to authenticated;
grant execute on function public.reopen_alert(uuid) to authenticated;
