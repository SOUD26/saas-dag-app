-- Módulo del guarda (2/5): puestos, catálogo de implementos, inventario por puesto y consignas.
-- Un sitio tiene uno o varios puestos ("Garita 24 h", "Recepción de día"). Cada puesto tiene su
-- horario, sus guardas requeridos, sus consignas y su inventario. El relevo se hace por puesto.

-- ---------- Ayudas para estados y niveles de alerta ----------
-- Niveles: red (actuar ya) > orange (revisar hoy) > yellow (revisar cuando se pueda).
create or replace function private.sev_rank(p text) returns int
language sql immutable set search_path = '' as $$
  select case p when 'red' then 3 when 'orange' then 2 when 'yellow' then 1 else 0 end
$$;

create or replace function private.sev_max(a text, b text) returns text
language sql immutable set search_path = '' as $$
  select case when private.sev_rank(a) >= private.sev_rank(b) then a else b end
$$;

-- "Mal estado" baja un nivel respecto a "falta" (nunca menos que amarilla).
create or replace function private.sev_down(p text) returns text
language sql immutable set search_path = '' as $$
  select case p when 'red' then 'orange' else 'yellow' end
$$;

create or replace function private.status_rank(p text) returns int
language sql immutable set search_path = '' as $$
  select case p when 'missing' then 2 when 'damaged' then 1 else 0 end
$$;

-- ---------- Puestos ----------
create table public.site_posts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  site_id uuid not null references public.sites(id) on delete cascade,
  name text not null,
  cover_from time not null default '06:00',
  cover_to time not null default '06:00',        -- igual a cover_from = cubre 24 horas
  shift_hours smallint not null default 12 check (shift_hours between 1 and 24),
  days smallint[] not null default '{1,2,3,4,5,6,7}',  -- 1 = lunes … 7 = domingo
  guards_required smallint not null default 1 check (guards_required between 0 and 50),
  orders text,                                  -- consignas del puesto
  orders_updated_at timestamptz,
  sort_order smallint not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint site_posts_days_ck check (cardinality(days) between 1 and 7 and days <@ '{1,2,3,4,5,6,7}'::smallint[]),
  constraint site_posts_orders_ck check (orders is null or length(orders) <= 4000)
);
create index site_posts_site_idx on public.site_posts (site_id);

alter table public.site_posts enable row level security;
create policy site_posts_select on public.site_posts for select to authenticated
  using (private.user_role() in ('super_admin', 'company_admin', 'supervisor', 'guard')
         and private.sees_site(site_id));
revoke all on public.site_posts from anon;
revoke insert, update, delete, truncate, references, trigger on public.site_posts from authenticated;
create trigger trg_audit_site_posts after insert or update on public.site_posts
  for each row execute function private.audit_changes('site_post', '', 'false');

-- ---------- Catálogo de implementos (por empresa) ----------
create table public.implement_types (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  name text not null,
  category text not null default 'equipo'
    check (category in ('arma', 'municion', 'comunicacion', 'acceso', 'proteccion', 'equipo', 'documento', 'otro')),
  severity text not null default 'yellow' check (severity in ('red', 'orange', 'yellow')),
  tracking text not null default 'unit' check (tracking in ('serial', 'count', 'unit')),
  needs_weapon_license boolean not null default false,
  active boolean not null default true,
  sort_order smallint not null default 100,
  created_at timestamptz not null default now()
);
create unique index implement_types_name_uq on public.implement_types (company_id, lower(name));

create or replace function private.implement_types_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.name := private.norm_text(new.name);
  if new.name is null then
    raise exception 'escribe el nombre del implemento' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' and new.company_id is distinct from old.company_id then
    raise exception 'un implemento no se cambia de empresa' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger trg_implement_types_before_write before insert or update on public.implement_types
  for each row execute function private.implement_types_before_write();
create trigger trg_audit_implement_types after insert or update on public.implement_types
  for each row execute function private.audit_changes('implement_type', '', 'true');

alter table public.implement_types enable row level security;
create policy implement_types_select on public.implement_types for select to authenticated
  using (private.user_role() = 'super_admin'
         or (company_id = private.user_company()
             and private.user_role() in ('company_admin', 'supervisor', 'guard')));
create policy implement_types_insert on public.implement_types for insert to authenticated
  with check (private.is_admin_of(company_id));
create policy implement_types_update on public.implement_types for update to authenticated
  using (private.is_admin_of(company_id)) with check (private.is_admin_of(company_id));
-- Sin borrado: un implemento se desactiva.
revoke all on public.implement_types from anon;
revoke delete, truncate, references, trigger on public.implement_types from authenticated;

-- Plantilla base. El color lo da el implemento: arma y munición rojo; radio, llaves, control del
-- portón y chaleco naranja; lo demás amarillo. Cada empresa lo ajusta.
create or replace function private.seed_implement_types(p_company uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.implement_types (company_id, name, category, severity, tracking, needs_weapon_license, sort_order)
  values
    (p_company, 'Escopeta',               'arma',         'red',    'serial', true,  10),
    (p_company, 'Revólver',               'arma',         'red',    'serial', true,  11),
    (p_company, 'Pistola',                'arma',         'red',    'serial', true,  12),
    (p_company, 'Munición',               'municion',     'red',    'count',  true,  20),
    (p_company, 'Radio',                  'comunicacion', 'orange', 'serial', false, 30),
    (p_company, 'Llaves',                 'acceso',       'orange', 'count',  false, 40),
    (p_company, 'Control del portón',     'acceso',       'orange', 'unit',   false, 41),
    (p_company, 'Chaleco antibalas',      'proteccion',   'orange', 'serial', false, 50),
    (p_company, 'Linterna',               'equipo',       'yellow', 'unit',   false, 60),
    (p_company, 'Tolete',                 'equipo',       'yellow', 'unit',   false, 61),
    (p_company, 'Gas pimienta',           'equipo',       'yellow', 'unit',   false, 62),
    (p_company, 'Esposas',                'equipo',       'yellow', 'unit',   false, 63),
    (p_company, 'Detector de metales',    'equipo',       'yellow', 'unit',   false, 64),
    (p_company, 'Capa impermeable',       'equipo',       'yellow', 'unit',   false, 65),
    (p_company, 'Botiquín',               'equipo',       'yellow', 'unit',   false, 66),
    (p_company, 'Cargador del teléfono',  'comunicacion', 'yellow', 'unit',   false, 70),
    (p_company, 'Gafetes de visitante',   'acceso',       'yellow', 'count',  false, 80),
    (p_company, 'Libro de novedades',     'documento',    'yellow', 'unit',   false, 90)
  on conflict do nothing;
end $$;

create or replace function private.companies_after_insert() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.company_subscriptions (company_id) values (new.id) on conflict do nothing;
  perform private.seed_document_types(new.id);
  perform private.seed_implement_types(new.id);
  return null;
end $$;

select private.seed_implement_types(id) from public.companies;

-- ---------- Inventario de cada puesto ----------
create table public.site_implements (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  site_id uuid not null references public.sites(id) on delete cascade,
  post_id uuid not null references public.site_posts(id) on delete cascade,
  type_id uuid not null references public.implement_types(id),
  label text,                     -- "Mossberg 500", "Manojo de la garita"
  serial text,                    -- número de serie (armas, radios, chalecos)
  quantity integer not null default 1 check (quantity between 1 and 10000),  -- cantidad esperada
  status text not null default 'ok' check (status in ('ok', 'damaged', 'missing')),  -- último estado conocido
  status_note text,
  status_at timestamptz,
  last_counted integer check (last_counted between 0 and 10000),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);
create index site_implements_post_idx on public.site_implements (post_id);
create index site_implements_site_idx on public.site_implements (site_id);

create or replace function private.site_implements_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.label := private.norm_text(new.label);
  new.serial := private.norm_text(new.serial);
  if not exists (select 1 from public.site_posts p
                 where p.id = new.post_id and p.site_id = new.site_id and p.company_id = new.company_id) then
    raise exception 'el puesto no pertenece a ese sitio' using errcode = '22023';
  end if;
  if not exists (select 1 from public.implement_types t where t.id = new.type_id and t.company_id = new.company_id) then
    raise exception 'tipo de implemento inválido' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger trg_site_implements_before_write before insert or update on public.site_implements
  for each row execute function private.site_implements_before_write();
create trigger trg_audit_site_implements_insert after insert on public.site_implements
  for each row execute function private.audit_changes('site_implement', '', 'true');
-- Los cambios de estado que vienen de un relevo ya quedan en el acta: no se repiten en la bitácora.
create trigger trg_audit_site_implements_update after update on public.site_implements
  for each row when (current_setting('app.in_handover', true) is distinct from 'on')
  execute function private.audit_changes('site_implement', '', 'true');

-- El guarda NO lee esta tabla: cuenta "a ciegas" en el relevo (ve la lista con post_checklist,
-- sin cantidades esperadas ni el último estado).
alter table public.site_implements enable row level security;
create policy site_implements_select on public.site_implements for select to authenticated
  using (private.user_role() in ('super_admin', 'company_admin', 'supervisor')
         and private.sees_site(site_id));
revoke all on public.site_implements from anon;
revoke insert, update, delete, truncate, references, trigger on public.site_implements from authenticated;

-- ---------- Puesto habitual del guarda y puesto de cada turno ----------
alter table public.guard_sites add column if not exists post_id uuid references public.site_posts(id) on delete set null;
alter table public.shifts add column if not exists post_id uuid references public.site_posts(id) on delete set null;

create or replace function private.check_post_in_site() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.post_id is not null and not exists (
       select 1 from public.site_posts p where p.id = new.post_id and p.site_id = new.site_id) then
    raise exception 'el puesto no pertenece a ese sitio' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger trg_guard_sites_post before insert or update on public.guard_sites
  for each row execute function private.check_post_in_site();
create trigger trg_shifts_post before insert or update on public.shifts
  for each row execute function private.check_post_in_site();

-- ---------- Sitios existentes: un "Puesto principal" de 24 h con sus guardas ----------
insert into public.site_posts (company_id, site_id, name, cover_from, cover_to, shift_hours, guards_required)
select s.company_id, s.id, 'Puesto principal', '06:00', '06:00', 12,
       greatest(1, (select count(*) from public.guard_sites gs where gs.site_id = s.id and gs.active))::smallint
from public.sites s
where not exists (select 1 from public.site_posts p where p.site_id = s.id);

update public.guard_sites gs
   set post_id = p.id
  from public.site_posts p
 where p.site_id = gs.site_id and gs.post_id is null;

-- DATOS DE DEMOSTRACIÓN: inventario básico en los sitios "Demo · …" (se borra en cascada con ellos).
insert into public.site_implements (company_id, site_id, post_id, type_id, label, serial, quantity)
select p.company_id, p.site_id, p.id, t.id,
       case t.name when 'Radio' then 'Motorola' when 'Llaves' then 'Manojo de la garita' end,
       case t.name when 'Radio' then 'RD-' || upper(substr(md5(p.id::text), 1, 5)) end,
       case t.name when 'Llaves' then 3 else 1 end
from public.site_posts p
join public.sites s on s.id = p.site_id and s.name like 'Demo · %'
join public.implement_types t on t.company_id = p.company_id and t.name in ('Radio', 'Linterna', 'Llaves');

insert into public.site_implements (company_id, site_id, post_id, type_id, label, serial, quantity)
select p.company_id, p.site_id, p.id, t.id,
       case t.name when 'Escopeta' then 'Calibre 12' end,
       case t.name when 'Escopeta' then 'ESC-' || upper(substr(md5(p.id::text), 1, 5)) end,
       case t.name when 'Munición' then 5 else 1 end
from public.site_posts p
join public.sites s on s.id = p.site_id and s.name = 'Demo · Bodega Zona 12'
join public.implement_types t on t.company_id = p.company_id and t.name in ('Escopeta', 'Munición');
