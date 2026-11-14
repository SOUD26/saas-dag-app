-- El catálogo de permisos pasa a ser el "registro" del panel de accesos:
-- cada módulo nuevo inserta aquí sus permisos (key, label, module, description, grantable_to)
-- y aparecen solos en el panel, sin tocar la pantalla.
alter table public.permissions add column if not exists label text;
alter table public.permissions add column if not exists module text;

update public.permissions set label = 'Gestionar reconocimiento facial', module = 'Reconocimiento facial' where key = 'caras.gestionar';
update public.permissions set label = 'Gestionar turnos', module = 'Turnos' where key = 'turnos.gestionar';
