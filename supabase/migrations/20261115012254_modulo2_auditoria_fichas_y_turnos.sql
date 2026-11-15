-- Módulo 2 · Bitácora (audit_log) de cambios en fichas, documentos, empresas, clientes, suscripciones y turnos.
-- Datos personales: solo se anota QUÉ columnas cambiaron, nunca los valores (no se copia un DPI a la bitácora).
-- Turnos y suscripciones: sí se anotan valores (horarios y cuotas; afectan la calificación y el cobro).

create or replace function private.audit_changes() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_entity text := tg_argv[0];
  v_target_col text := nullif(tg_argv[1], '');
  v_with_values boolean := coalesce(nullif(tg_argv[2], '')::boolean, false);
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_company uuid;
  v_target uuid;
  v_detail text;
  v_extra text;
begin
  v_company := coalesce(private.try_uuid(v_row ->> 'company_id'),
                        case when v_entity = 'company' then private.try_uuid(v_row ->> 'id') end);
  if v_target_col is not null then
    v_target := private.try_uuid(v_row ->> v_target_col);
  end if;

  if tg_op = 'UPDATE' then
    select string_agg(
             case when v_with_values
                  then k || ': ' || coalesce(v_old ->> k, '—') || ' → ' || coalesce(v_new ->> k, '—')
                  else k end, '; ' order by k)
      into v_detail
      from jsonb_object_keys(v_new) as k
     where k not in ('updated_at', 'updated_by', 'created_at', 'created_by')
       and (v_new -> k) is distinct from (v_old -> k);
    if v_detail is null then
      return null;  -- no cambió nada relevante
    end if;
  end if;

  if v_entity = 'document' then
    select t.name into v_extra from public.document_types t where t.id = private.try_uuid(v_row ->> 'type_id');
    v_detail := concat_ws(' · ', v_extra, v_detail);
  elsif v_entity = 'subscription' then
    -- La suscripción es asunto del súper admin: la fila de bitácora no se asocia a la empresa
    -- (así el admin de la empresa no la ve en su bitácora).
    select c.name into v_extra from public.companies c where c.id = v_company;
    v_detail := concat_ws(' · ', v_extra, v_detail);
    v_company := null;
  end if;

  insert into public.audit_log (company_id, actor, action, target_user, detail)
  values (v_company, (select auth.uid()),
          v_entity || case tg_op when 'INSERT' then '_created' when 'UPDATE' then '_updated' else '_deleted' end,
          v_target, v_detail);
  return null;
end $$;

create trigger trg_audit_staff_records after insert or update on public.staff_records
  for each row execute function private.audit_changes('staff_record', 'profile_id', 'false');

create trigger trg_audit_documents after insert or update or delete on public.documents
  for each row execute function private.audit_changes('document', 'profile_id', 'false');

create trigger trg_audit_document_types after insert or update on public.document_types
  for each row execute function private.audit_changes('document_type', '', 'false');

create trigger trg_audit_companies after insert or update on public.companies
  for each row execute function private.audit_changes('company', '', 'false');

create trigger trg_audit_clients after insert or update on public.clients
  for each row execute function private.audit_changes('client', '', 'false');

create trigger trg_audit_subscriptions after update on public.company_subscriptions
  for each row execute function private.audit_changes('subscription', '', 'true');

-- Pendiente del módulo 2: cambios de turnos (afectan la calificación del guarda).
create trigger trg_audit_shifts after update on public.shifts
  for each row execute function private.audit_changes('shift', 'guard_id', 'true');
