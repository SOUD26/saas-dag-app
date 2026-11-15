-- Módulo del guarda (1/5): sitios con aprobación, levantamiento de seguridad, servicios y
-- administradores del cliente.
-- Flujo: el supervisor propone (borrador → por aprobar) y el administrador aprueba o devuelve.
-- Un sitio creado por el administrador nace aprobado. Solo un sitio aprobado puede estar activo.
-- Todas las escrituras pasan por funciones (save_site, approve_site, return_site): la app ya no
-- inserta ni edita sitios directo (solo puede activar o desactivar).

alter table public.sites
  add column if not exists status text not null default 'approved',
  add column if not exists address text,
  add column if not exists proposed_by uuid references public.profiles(id) on delete set null,
  add column if not exists submitted_at timestamptz,
  add column if not exists approved_by uuid references public.profiles(id) on delete set null,
  add column if not exists approved_at timestamptz,
  add column if not exists review_note text,
  add column if not exists proposed_client_name text,
  add column if not exists rounds_required boolean not null default false,
  add column if not exists rounds_every_minutes smallint,
  add column if not exists visitor_control boolean not null default false,
  add column if not exists survey jsonb not null default '{}'::jsonb,
  add column if not exists survey_at timestamptz,
  add column if not exists survey_by uuid references public.profiles(id) on delete set null,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid;

alter table public.sites add constraint sites_status_ck
  check (status in ('draft', 'pending', 'returned', 'approved'));
alter table public.sites add constraint sites_active_only_approved_ck
  check (status = 'approved' or not active);
alter table public.sites add constraint sites_rounds_ck
  check (rounds_every_minutes is null or rounds_every_minutes between 15 and 1440);
alter table public.sites add constraint sites_survey_ck
  check (jsonb_typeof(survey) = 'object');

create index if not exists sites_status_idx on public.sites (company_id, status);

-- Normaliza textos y protege los datos del flujo de aprobación.
create or replace function private.sites_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.name := private.norm_text(new.name);
  if new.name is null then
    raise exception 'escribe el nombre del sitio' using errcode = '22023';
  end if;
  new.address := private.norm_text(new.address);
  new.proposed_client_name := private.norm_text(new.proposed_client_name);
  new.review_note := private.norm_text(new.review_note);
  if tg_op = 'UPDATE' then
    if new.company_id is distinct from old.company_id then
      raise exception 'un sitio no se cambia de empresa' using errcode = '22023';
    end if;
    new.updated_at := now();
    new.updated_by := (select auth.uid());
  end if;
  return new;
end $$;

create trigger trg_sites_before_write before insert or update on public.sites
  for each row execute function private.sites_before_write();
create trigger trg_audit_sites after insert or update on public.sites
  for each row execute function private.audit_changes('site', '', 'false');

-- La app solo puede activar/desactivar un sitio directo (RLS: solo el admin de la empresa).
revoke insert, update on public.sites from authenticated;
grant update (active) on public.sites to authenticated;

-- ---------- Administradores y contactos del cliente en el sitio ----------
create table public.site_contacts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  site_id uuid not null references public.sites(id) on delete cascade,
  full_name text not null,
  job_title text,                 -- Administrador, Junta directiva, Conserje…
  phone text,
  email text,
  is_admin boolean not null default false,   -- administrador del cliente (a quien se capacita)
  profile_id uuid references public.profiles(id) on delete set null,  -- su usuario, cuando exista
  trained_at date,                -- fecha de la capacitación
  trained_by uuid references public.profiles(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid()
);
create index site_contacts_site_idx on public.site_contacts (site_id);

alter table public.site_contacts enable row level security;
create policy site_contacts_select on public.site_contacts for select to authenticated
  using (private.user_role() in ('super_admin', 'company_admin', 'supervisor')
         and private.sees_site(site_id));
-- Se escriben solo con save_site.
revoke all on public.site_contacts from anon;
revoke insert, update, delete, truncate, references, trigger on public.site_contacts from authenticated;

-- La bitácora anota qué columnas cambiaron, nunca los valores (son datos personales).
create trigger trg_audit_site_contacts after insert or update on public.site_contacts
  for each row execute function private.audit_changes('site_contact', '', 'false');

-- ---------- Clientes para elegir (el supervisor no ve la ficha de los clientes) ----------
create or replace function public.client_options(p_company uuid default null)
returns table (id uuid, name text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_company uuid := coalesce(p_company, private.user_company());
begin
  if v_company is null or not coalesce(
       private.is_admin_of(v_company)
       or (private.user_role() = 'supervisor' and private.user_company() = v_company), false) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  return query
    select c.id, c.name from public.clients c
    where c.company_id = v_company and c.active
    order by c.name;
end $$;

-- ---------- Aprobar o devolver una propuesta ----------
create or replace function public.approve_site(p_site uuid, p_client uuid default null, p_new_client_name text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v public.sites%rowtype;
  v_client uuid;
  v_name text;
begin
  select * into v from public.sites where id = p_site for update;
  if not found or not private.is_admin_of(v.company_id) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  if v.status <> 'pending' then
    raise exception 'este sitio no está por aprobar' using errcode = '22023';
  end if;
  if not exists (select 1 from public.site_posts p where p.site_id = p_site and p.active) then
    raise exception 'el sitio necesita al menos un puesto' using errcode = '22023';
  end if;

  v_client := coalesce(p_client, v.client_id);
  if v_client is null then
    v_name := private.norm_text(coalesce(p_new_client_name, v.proposed_client_name));
    if v_name is not null then
      insert into public.clients (company_id, name) values (v.company_id, v_name) returning id into v_client;
    end if;
  end if;
  if v_client is not null and not exists (
       select 1 from public.clients c where c.id = v_client and c.company_id = v.company_id) then
    raise exception 'cliente inválido' using errcode = '22023';
  end if;

  update public.sites
     set status = 'approved', active = true,
         approved_by = (select auth.uid()), approved_at = now(),
         review_note = null, client_id = v_client,
         proposed_client_name = case when v_client is null then proposed_client_name end
   where id = p_site;

  insert into public.audit_log (company_id, actor, action, target_user, detail)
  values (v.company_id, (select auth.uid()), 'site_approved', v.proposed_by, v.name);
end $$;

create or replace function public.return_site(p_site uuid, p_note text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v public.sites%rowtype;
begin
  select * into v from public.sites where id = p_site for update;
  if not found or not private.is_admin_of(v.company_id) then
    raise exception 'no autorizado' using errcode = '42501';
  end if;
  if v.status <> 'pending' then
    raise exception 'este sitio no está por aprobar' using errcode = '22023';
  end if;
  if private.norm_text(p_note) is null then
    raise exception 'escribe qué debe corregir el supervisor' using errcode = '22023';
  end if;
  update public.sites set status = 'returned', review_note = p_note where id = p_site;
  insert into public.audit_log (company_id, actor, action, target_user, detail)
  values (v.company_id, (select auth.uid()), 'site_returned', v.proposed_by, v.name);
end $$;

revoke execute on function public.client_options(uuid) from public, anon;
revoke execute on function public.approve_site(uuid, uuid, text) from public, anon;
revoke execute on function public.return_site(uuid, text) from public, anon;
grant execute on function public.client_options(uuid) to authenticated;
grant execute on function public.approve_site(uuid, uuid, text) to authenticated;
grant execute on function public.return_site(uuid, text) to authenticated;
