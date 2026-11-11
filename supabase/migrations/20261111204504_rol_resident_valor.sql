-- Rol "Usuario" (condómino, propietario de local, residente). Va en migración aparte
-- porque un valor nuevo de enum no se puede usar en la misma transacción.
alter type public.app_role add value if not exists 'resident';
