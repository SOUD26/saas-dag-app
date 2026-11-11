-- Código corto de empresa (lo escribe el guarda al entrar) y regla del rol resident.
alter table public.companies
  add column if not exists code text not null
  default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));

create unique index if not exists companies_code_uk on public.companies (lower(code));

alter table public.profiles drop constraint if exists profiles_client_ck;
alter table public.profiles add constraint profiles_client_ck
  check ((role in ('client', 'resident')) = (client_id is not null));

create or replace function public.authorize_user_creation(p_caller uuid, p_role public.app_role, p_company uuid, p_client uuid)
returns void
language plpgsql
stable security definer
set search_path = ''
as $function$
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

  if p_role in ('client', 'resident') then
    if p_client is null or not exists (select 1 from public.clients where id = p_client and company_id = p_company) then
      raise exception 'cliente inválido' using errcode = '22023';
    end if;
  elsif p_client is not null then
    raise exception 'solo los roles cliente y usuario llevan cliente' using errcode = '22023';
  end if;
end $function$;
