import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/profile.dart';
import '../screens/admin/admin_home.dart';
import '../screens/login_screen.dart';
import '../screens/no_access_screen.dart';
import '../screens/role_screen.dart';
import '../supabase.dart';
import '../theme.dart';

/// Decide qué pantalla se ve: login, "sin acceso" o la pantalla del rol.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final StreamSubscription<AuthState> _sub;
  String? _userId = supabase.auth.currentUser?.id;
  Future<Profile?>? _profile;

  @override
  void initState() {
    super.initState();
    _profile = _load();
    _sub = supabase.auth.onAuthStateChange.listen((data) {
      final newId = data.session?.user.id;
      if (newId == _userId) return;
      setState(() {
        _userId = newId;
        _profile = _load();
      });
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  Future<Profile?> _load() async {
    final user = supabase.auth.currentUser;
    if (user == null) return null;
    final row = await supabase
        .from('profiles')
        .select('id, role, full_name, active, companies(name, code), clients(name)')
        .eq('id', user.id)
        .maybeSingle();
    if (row == null) return null;
    return Profile.fromRow(row);
  }

  void _retry() => setState(() => _profile = _load());

  @override
  Widget build(BuildContext context) {
    if (_userId == null) return const LoginScreen();

    return FutureBuilder<Profile?>(
      future: _profile,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator(color: AppColors.navy)),
          );
        }
        if (snap.hasError) {
          return NoAccessScreen(
            title: 'No pudimos cargar tu cuenta',
            message: 'Revisa tu conexión e intenta de nuevo.',
            onRetry: _retry,
          );
        }
        final profile = snap.data;
        if (profile == null) {
          return const NoAccessScreen(
            title: 'Tu cuenta aún no tiene acceso',
            message:
                'Ingresaste correctamente, pero tu correo no está dado de alta. '
                'Pide a tu administrador que te cree el usuario.',
          );
        }
        if (!profile.active) {
          return const NoAccessScreen(
            title: 'Cuenta desactivada',
            message: 'Tu acceso fue desactivado. Habla con tu administrador.',
          );
        }
        if (profile.role == AppRole.companyAdmin) return AdminHome(profile: profile);
        return RoleScreen(profile: profile);
      },
    );
  }
}
