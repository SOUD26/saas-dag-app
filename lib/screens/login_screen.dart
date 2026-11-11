import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../supabase.dart';
import '../theme.dart';
import '../widgets/brand.dart';

enum _Mode { staff, guard }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _companyKey = 'last_company_code';

  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _company = TextEditingController();
  final _user = TextEditingController();

  _Mode _mode = _Mode.staff;
  bool _busy = false;
  bool _hidePassword = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restoreCompany();
  }

  Future<void> _restoreCompany() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_companyKey);
      if (saved != null && mounted && _company.text.isEmpty) {
        _company.text = saved;
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _company.dispose();
    _user.dispose();
    super.dispose();
  }

  void _switchMode(_Mode mode) {
    setState(() {
      _mode = mode;
      _error = null;
      _password.clear();
      _formKey.currentState?.reset();
    });
  }

  String _friendly(AuthException e) {
    final msg = e.message.toLowerCase();
    if (msg.contains('invalid login credentials')) {
      return _mode == _Mode.guard
          ? 'Código de empresa, usuario o contraseña incorrectos.'
          : 'Correo o contraseña incorrectos.';
    }
    if (msg.contains('rate limit') || e.code == 'over_request_rate_limit') {
      return 'Demasiados intentos. Espera un momento e intenta de nuevo.';
    }
    if (msg.contains('not confirmed')) {
      return 'Tu correo aún no está confirmado.';
    }
    return 'No se pudo iniciar sesión. Intenta de nuevo.';
  }

  Future<void> _submit() async {
    if (_busy || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final guard = _mode == _Mode.guard;
      final email = guard
          ? AppConfig.guardEmail(_user.text, _company.text)
          : _email.text.trim();
      await supabase.auth.signInWithPassword(email: email, password: _password.text);
      if (guard) {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_companyKey, _company.text.trim().toUpperCase());
        } catch (_) {}
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No hay conexión. Revisa tu internet e intenta de nuevo.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _google() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await supabase.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: kIsWeb ? null : AppConfig.mobileRedirect,
      );
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo abrir el acceso con Google.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 900;
          final form = _buildForm();
          if (wide) {
            return Row(
              children: [
                const Expanded(flex: 5, child: _BrandPanel()),
                Expanded(
                  flex: 4,
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(32),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: form,
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          return SingleChildScrollView(
            child: Column(
              children: [
                const _CompactHeader(),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
                      child: form,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildForm() {
    final guard = _mode == _Mode.guard;
    return AutofillGroup(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              guard ? 'Acceso de guardas' : 'Bienvenido',
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              guard
                  ? 'Ingresa con el código de tu empresa y tu usuario.'
                  : 'Ingresa para continuar.',
              style: const TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 24),
            if (!guard) ...[
              OutlinedButton.icon(
                onPressed: _busy ? null : _google,
                icon: const _GoogleG(),
                label: const Text('Continuar con Google'),
              ),
              const SizedBox(height: 18),
              const _OrDivider(),
              const SizedBox(height: 18),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                  labelText: 'Correo electrónico',
                  prefixIcon: Icon(Icons.mail_outline_rounded),
                ),
                validator: (v) {
                  final t = v?.trim() ?? '';
                  if (t.isEmpty) return 'Escribe tu correo';
                  if (!t.contains('@') || !t.contains('.')) return 'Correo no válido';
                  return null;
                },
              ),
            ] else ...[
              TextFormField(
                controller: _company,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Código de empresa',
                  hintText: 'Ej. C98EA0',
                  prefixIcon: Icon(Icons.business_rounded),
                ),
                validator: (v) =>
                    (v?.trim().isEmpty ?? true) ? 'Escribe el código de tu empresa' : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _user,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.username],
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Usuario',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
                validator: (v) =>
                    (v?.trim().isEmpty ?? true) ? 'Escribe tu usuario' : null,
              ),
            ],
            const SizedBox(height: 14),
            TextFormField(
              controller: _password,
              obscureText: _hidePassword,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Contraseña',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  tooltip: _hidePassword ? 'Mostrar' : 'Ocultar',
                  icon: Icon(
                    _hidePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _hidePassword = !_hidePassword),
                ),
              ),
              validator: (v) => (v?.isEmpty ?? true) ? 'Escribe tu contraseña' : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              _ErrorBox(message: _error!),
            ],
            const SizedBox(height: 22),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                    )
                  : const Text('Ingresar'),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: _busy ? null : () => _switchMode(guard ? _Mode.staff : _Mode.guard),
              child: Text(
                guard ? 'Volver al acceso general' : 'Soy guarda de seguridad',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.navy, AppColors.navyLight],
        ),
      ),
      padding: const EdgeInsets.all(56),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LogoMark(size: 64),
          const SizedBox(height: 28),
          const Text(
            AppConfig.appName,
            style: TextStyle(
              color: Colors.white,
              fontSize: 44,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            AppConfig.tagline,
            style: TextStyle(color: Colors.white70, fontSize: 18, height: 1.4),
          ),
          const SizedBox(height: 40),
          const _Point(icon: Icons.verified_user_rounded, text: 'Guarda verificado en su puesto'),
          const _Point(icon: Icons.map_rounded, text: 'Sitios y rondas en un solo mapa'),
          const _Point(icon: Icons.history_rounded, text: 'Bitácora que nadie puede alterar'),
        ],
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(icon, color: AppColors.amber, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 15)),
          ),
        ],
      ),
    );
  }
}

class _CompactHeader extends StatelessWidget {
  const _CompactHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(24, MediaQuery.of(context).padding.top + 32, 24, 32),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.navy, AppColors.navyLight],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
      ),
      child: const Column(
        children: [
          LogoMark(size: 56),
          SizedBox(height: 16),
          Text(
            AppConfig.appName,
            style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 6),
          Text(
            AppConfig.tagline,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: Divider(color: AppColors.line)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text('o con tu correo', style: TextStyle(color: AppColors.muted, fontSize: 13)),
        ),
        Expanded(child: Divider(color: AppColors.line)),
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: const TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }
}

/// "G" de Google dibujada con texto de colores (sin depender de imágenes).
class _GoogleG extends StatelessWidget {
  const _GoogleG();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'G',
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w800,
        color: Color(0xFF4285F4),
      ),
    );
  }
}
