/// Valores públicos de la app. La clave "publishable" es pública por diseño:
/// la seguridad real está en las reglas (RLS) de la base de datos.
class AppConfig {
  static const appName = 'SaaS-DAG';
  static const tagline = 'Control y monitoreo para empresas de seguridad';

  static const supabaseUrl = 'https://tkjgavqmiyinhnvvckvo.supabase.co';
  static const supabaseKey = 'sb_publishable_MvO7khKCreAcn5rCNVOPOw_4bneumYx';

  /// Dirección a la que Google devuelve al usuario en Android.
  static const mobileRedirect = 'com.saasdag.app://login-callback';

  /// Dominio interno de los guardas: usuario@codigo.guardas.invalid
  static String guardEmail(String user, String companyCode) =>
      '${user.trim().toLowerCase()}@${companyCode.trim().toLowerCase()}.guardas.invalid';
}
