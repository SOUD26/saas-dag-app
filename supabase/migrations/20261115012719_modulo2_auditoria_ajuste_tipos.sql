-- La plantilla de 14 tipos que nace con cada empresa no ensucia la bitácora:
-- solo se anotan los tipos que crea la empresa (key vacía) y los cambios al catálogo.
drop trigger if exists trg_audit_document_types on public.document_types;

create trigger trg_audit_document_types_insert after insert on public.document_types
  for each row when (new.key is null)
  execute function private.audit_changes('document_type', '', 'false');

create trigger trg_audit_document_types_update after update on public.document_types
  for each row execute function private.audit_changes('document_type', '', 'false');
