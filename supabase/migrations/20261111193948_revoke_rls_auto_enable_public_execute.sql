-- Función auxiliar de Supabase que no debe poder llamarse desde la API pública.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
