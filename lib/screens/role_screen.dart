import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../models/role_info.dart';
import '../supabase.dart';
import '../theme.dart';

/// Pantalla vacía por rol. Sirve para comprobar que cada login cae donde toca.
/// Si [previewRole] viene lleno es una vista previa (solo el súper admin).
class RoleScreen extends StatelessWidget {
  const RoleScreen({super.key, required this.profile, this.previewRole});

  final Profile profile;
  final AppRole? previewRole;

  AppRole get _role => previewRole ?? profile.role;
  bool get _isPreview => previewRole != null;

  @override
  Widget build(BuildContext context) {
    final info = infoFor(_role);
    final canPreview = profile.role == AppRole.superAdmin && !_isPreview;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: Text(info.title),
        actions: [
          if (!_isPreview)
            IconButton(
              tooltip: 'Cerrar sesión',
              icon: const Icon(Icons.logout_rounded),
              onPressed: () => supabase.auth.signOut(),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_isPreview)
            Container(
              width: double.infinity,
              color: AppColors.amber,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                'Vista previa: así la verá un ${_role.label.toLowerCase()}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.navy),
              ),
            ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    _Header(info: info, profile: profile, role: _role, preview: _isPreview),
                    const SizedBox(height: 24),
                    const Text(
                      'Módulos',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 12),
                    _ModuleGrid(modules: info.modules, color: info.color),
                    if (canPreview) ...[
                      const SizedBox(height: 28),
                      _PreviewPicker(profile: profile),
                    ],
                    const SizedBox(height: 28),
                    Center(
                      child: Text(
                        'Rol detectado: ${_role.label} · v0.1 de prueba',
                        style: const TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.info,
    required this.profile,
    required this.role,
    required this.preview,
  });

  final RoleInfo info;
  final Profile profile;
  final AppRole role;
  final bool preview;

  @override
  Widget build(BuildContext context) {
    final where = [
      if (profile.companyName != null) profile.companyName!,
      if (profile.clientName != null) profile.clientName!,
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: info.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(info.icon, color: info.color, size: 34),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  preview ? info.title : 'Hola, ${profile.firstName}',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(info.subtitle, style: const TextStyle(color: AppColors.muted)),
                if (!preview && where.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(where, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                ],
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: info.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    role.label,
                    style: TextStyle(
                      color: info.color,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ModuleGrid extends StatelessWidget {
  const _ModuleGrid({required this.modules, required this.color});

  final List<String> modules;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 700 ? 3 : (c.maxWidth >= 440 ? 2 : 1);
        const gap = 12.0;
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final m in modules)
              SizedBox(
                width: w,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.widgets_outlined, color: color),
                      const SizedBox(height: 12),
                      Text(m, style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      const Text(
                        'Próximamente',
                        style: TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PreviewPicker extends StatelessWidget {
  const _PreviewPicker({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final roles = AppRole.values.where((r) => r != AppRole.superAdmin);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.navy,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Vista previa por rol',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text(
            'Solo la ves tú. Abre la pantalla de cada rol sin cerrar sesión.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final r in roles)
                ActionChip(
                  avatar: Icon(infoFor(r).icon, size: 18, color: AppColors.navy),
                  label: Text(r.label),
                  backgroundColor: AppColors.amber,
                  side: BorderSide.none,
                  labelStyle: const TextStyle(
                    color: AppColors.navy,
                    fontWeight: FontWeight.w700,
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RoleScreen(profile: profile, previewRole: r),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
