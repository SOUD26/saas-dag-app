-- Perfiles: usuario (guardas) y correo (el resto). Solo lectura desde la app.
alter table public.profiles add column username text;
alter table public.profiles add column email text;
alter table public.profiles add constraint profiles_guard_username_ck check (role <> 'guard' or username is not null);
alter table public.profiles add constraint profiles_email_ck check (role = 'guard' or email is not null);
create unique index profiles_username_uq on public.profiles (company_id, lower(username)) where username is not null;
create unique index profiles_email_uq on public.profiles (lower(email)) where email is not null;

-- ¿Puede quien llama crear un usuario con este rol en esta empresa? (solo service_role la ejecuta)
create function public.authorize_user_creation(p_caller uuid, p_role public.app_role, p_company uuid, p_client uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
declare
  c public.profiles%rowtype;
begin
  select p.* into c from public.profiles p
  left join public.companies co on co.id = p.company_id
  where p.id = p_caller and p.active and (p.company_id is null or co.active);
  if not found then raise exception 'no autorizado' using errcode = '42501'; end if;

  if p_role = 'super_admin' then
    raise exception 'los súper admin no se crean desde la app' using errcode = '42501';
  end if;
  if p_company is null or not exists (select 1 from public.companies where id = p_company and active) then
    raise exception 'empresa inválida' using errcode = '22023';
  end if;

  if c.role = 'super_admin' then
    null;
  elsif c.role = 'company_admin' then
    if c.company_id is distinct from p_company then
      raise exception 'no autorizado' using errcode = '42501';
    end if;
  else
    raise exception 'no autorizado' using errcode = '42501';
  end if;

  if p_role = 'client' then
    if p_client is null or not exists (select 1 from public.clients where id = p_client and company_id = p_company) then
      raise exception 'cliente inválido' using errcode = '22023';
    end if;
  elsif p_client is not null then
    raise exception 'solo el rol cliente lleva cliente' using errcode = '22023';
  end if;
end $$;

-- Crea el perfil y deja constancia en la bitácora (una sola operación)
create function public.provision_user(
  p_caller uuid, p_new_id uuid, p_role public.app_role, p_company uuid, p_client uuid,
  p_full_name text, p_username text, p_email text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.authorize_user_creation(p_caller, p_role, p_company, p_client);
  if nullif(trim(p_full_name), '') is null then
    raise exception 'nombre requerido' using errcode = '22023';
  end if;
  insert into public.profiles (id, company_id, client_id, role, full_name, username, email)
  values (p_new_id, p_company, p_client, p_role, trim(p_full_name), lower(p_username), lower(p_email));
  insert into public.audit_log (company_id, actor, action, target_user, detail)
  values (p_company, p_caller, 'user_created', p_new_id, p_role::text);
end $$;

-- ¿Puede quien llama cambiar la contraseña de este usuario?
create function public.authorize_user_management(p_caller uuid, p_target uuid)
returns void language plpgsql stable security definer set search_path = '' as $$
declare
  c public.profiles%rowtype;
  t public.profiles%rowtype;
begin
  select p.* into c from public.profiles p
  left join public.companies co on co.id = p.company_id
  where p.id = p_caller and p.active and (p.company_id is null or co.active);
  if not found then raise exception 'no autorizado' using errcode = '42501'; end if;
  select * into t from public.profiles where id = p_target;
  if not found then raise exception 'usuario no encontrado' using errcode = '22023'; end if;
  if p_caller = p_target then raise exception 'use la pantalla de cambio de contraseña propia' using errcode = '42501'; end if;

  if c.role = 'super_admin' then
    if t.role = 'super_admin' then raise exception 'no autorizado' using errcode = '42501'; end if;
  elsif c.role = 'company_admin' then
    if t.company_id is distinct from c.company_id or t.role in ('super_admin','company_admin') then
      raise exception 'no autorizado' using errcode = '42501';
    end if;
  else
    raise exception 'no autorizado' using errcode = '42501';
  end if;
end $$;

create function public.log_password_reset(p_caller uuid, p_target uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform public.authorize_user_management(p_caller, p_target);
  insert into public.audit_log (company_id, actor, action, target_user)
  select company_id, p_caller, 'password_reset', id from public.profiles where id = p_target;
end $$;

revoke execute on function public.authorize_user_creation(uuid, public.app_role, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.provision_user(uuid, uuid, public.app_role, uuid, uuid, text, text, text) from public, anon, authenticated;
revoke execute on function public.authorize_user_management(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.log_password_reset(uuid, uuid) from public, anon, authenticated;
grant execute on function public.authorize_user_creation(uuid, public.app_role, uuid, uuid) to service_role;
grant execute on function public.provision_user(uuid, uuid, public.app_role, uuid, uuid, text, text, text) to service_role;
grant execute on function public.authorize_user_management(uuid, uuid) to service_role;
grant execute on function public.log_password_reset(uuid, uuid) to service_role;
