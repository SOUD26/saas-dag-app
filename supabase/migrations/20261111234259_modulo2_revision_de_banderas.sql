-- Módulo 2: revisión de banderas por el administrador.
-- Resultado: justified (Justificada), false_alarm (Falsa alarma), action_required (Requiere acción).
alter table public.shift_verifications
  add column if not exists reviewed_by uuid references public.profiles(id) on delete set null,
  add column if not exists reviewed_at timestamptz,
  add column if not exists review_outcome text;

alter table public.shift_verifications drop constraint if exists shift_verifications_review_ck;
alter table public.shift_verifications add constraint shift_verifications_review_ck check (
  (review_outcome is null or review_outcome in ('justified','false_alarm','action_required'))
  and ((reviewed_at is null) = (review_outcome is null)));

create index if not exists shift_verifications_flagged_idx
  on public.shift_verifications (company_id, created_at desc) where flagged;

-- review_verification(p_id, p_outcome) y reopen_verification(p_id): funciones
-- SECURITY DEFINER (search_path vacío) que exigen private.is_admin_of(company_id),
-- registran en audit_log ('verification_reviewed' / 'verification_reopened') y se
-- conceden solo a 'authenticated'. Aplicadas directo en Supabase (versión 20261111234259);
-- la definición vigente vive en la base de datos.
