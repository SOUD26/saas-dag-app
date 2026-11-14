-- Módulo 2: turnos de los guardas (horarios por sitio) y bitácora de turnos.
-- Un guarda puede tener turno diurno en un sitio una semana y nocturno en otro la siguiente.
-- La bitácora (shift_log) se CALCULA al vuelo desde turnos + verificaciones, así que a futuro
-- se pueden agregar puntos o calificaciones sin reescribir historia.

create extension if not exists btree_gist with schema extensions;

insert into public.permissions (key, description, grantable_to)
values ('turnos.gestionar', 'Crear, cambiar y cancelar turnos de los guardas de sus sitios', '{supervisor}')
on conflict (key) do nothing;

create or replace function private.can_manage_shifts(p_site uuid, p_company uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    private.is_admin_of(p_company)
    or (
      private.user_role() = 'supervisor'
      and private.user_company() = p_company
      and private.sees_site(p_site)
      and exists (
        select 1 from public.user_permissions up
        where up.user_id = (select auth.uid())
          and up.permission = 'turnos.gestionar'
          and up.company_id = p_company
      )
    ),
    false)
$$;

create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  site_id uuid not null references public.sites(id),
  guard_id uuid not null references public.profiles(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  grace_minutes int not null default 10 check (grace_minutes between 0 and 120),
  cancelled boolean not null default false,
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at > starts_at),
  check (ends_at - starts_at <= interval '24 hours'),
  -- un guarda no puede tener dos turnos al mismo tiempo (los cancelados no cuentan)
  constraint shifts_no_overlap exclude using gist (
    guard_id with =,
    tstzrange(starts_at, ends_at) with &&
  ) where (not cancelled)
);

create index shifts_guard_idx on public.shifts (guard_id, starts_at);
create index shifts_site_idx on public.shifts (site_id, starts_at);
create index shifts_company_idx on public.shifts (company_id, starts_at);

alter table public.shifts enable row level security;

create policy shifts_select on public.shifts for select to authenticated using (
  private.is_admin_of(company_id)
  or guard_id = (select auth.uid())
  or (private.user_role() = 'supervisor' and private.sees_site(site_id))
);

create policy shifts_insert on public.shifts for insert to authenticated with check (
  private.can_manage_shifts(site_id, company_id)
  and private.site_in(site_id, company_id)
  and private.profile_in(guard_id, company_id, 'guard'::app_role)
);

create policy shifts_update on public.shifts for update to authenticated
using (private.can_manage_shifts(site_id, company_id))
with check (
  private.can_manage_shifts(site_id, company_id)
  and private.site_in(site_id, company_id)
  and private.profile_in(guard_id, company_id, 'guard'::app_role)
);
-- Sin política de borrado: un turno se cancela, no se borra.

revoke all on public.shifts from anon;
revoke delete, truncate, references, trigger on public.shifts from authenticated;

-- Bitácora: una fila por turno con su resultado.
create view public.shift_log with (security_invoker = true) as
select
  s.id as shift_id,
  s.company_id,
  s.site_id,
  s.guard_id,
  s.starts_at,
  s.ends_at,
  s.grace_minutes,
  s.cancelled,
  s.notes,
  v.arrived_at,
  case when v.arrived_at is null then null
       else greatest(0, ceil(extract(epoch from (v.arrived_at - s.starts_at)) / 60))::int
  end as late_minutes,
  coalesce(v.checks, 0) as checks,
  coalesce(v.flags, 0) as flags,
  case
    when s.cancelled then 'cancelado'
    when v.arrived_at is not null
         and v.arrived_at <= s.starts_at + make_interval(mins => s.grace_minutes) then 'a_tiempo'
    when v.arrived_at is not null then 'tarde'
    when now() < s.starts_at then 'programado'
    when now() <= s.starts_at + make_interval(mins => s.grace_minutes) then 'por_iniciar'
    when now() <= s.ends_at then 'sin_llegada'
    else 'ausente'
  end as status
from public.shifts s
left join lateral (
  select
    min(sv.created_at) filter (where sv.kind = 'shift_start') as arrived_at,
    count(*) as checks,
    count(*) filter (where sv.flagged) as flags
  from public.shift_verifications sv
  where sv.guard_id = s.guard_id
    and sv.site_id = s.site_id
    and sv.created_at >= s.starts_at - interval '2 hours'
    and sv.created_at <= s.ends_at
) v on true;

revoke all on public.shift_log from anon;
grant select on public.shift_log to authenticated;

-- DATOS DE DEMOSTRACIÓN (notes = 'Demo'): turnos que coinciden con las verificaciones de prueba.
-- Para borrarlos: delete from public.shifts where notes = 'Demo';
insert into public.shifts (company_id, site_id, guard_id, starts_at, ends_at, notes)
select distinct on (v.guard_id, (v.created_at at time zone 'America/Guatemala')::date)
  v.company_id, v.site_id, v.guard_id,
  date_trunc('minute', v.created_at) - ((abs(hashtext(v.id::text)) % 26) - 6) * interval '1 minute',
  date_trunc('minute', v.created_at) - ((abs(hashtext(v.id::text)) % 26) - 6) * interval '1 minute' + interval '8 hours',
  'Demo'
from public.shift_verifications v
where v.kind = 'shift_start'
order by v.guard_id, (v.created_at at time zone 'America/Guatemala')::date, v.created_at
on conflict do nothing;
