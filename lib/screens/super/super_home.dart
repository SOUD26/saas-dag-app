// Pantalla de inicio del súper administrador ("Nosotros"): todas las empresas de seguridad.
import 'package:flutter/material.dart';

import '../../models/profile.dart';
import '../../supabase.dart';
import '../../theme.dart';
import '../admin/admin_ui.dart';
import '../admin/staff_file.dart';
import '../role_screen.dart';
import 'company_form.dart';
import 'company_page.dart';
import 'super_data.dart';

class SuperHome extends StatefulWidget {
  const SuperHome({super.key, required this.profile});
  final Profile profile;

  @override
  State<SuperHome> createState() => _SuperHomeState();
}

class _SuperHomeState extends State<SuperHome> {
  List<CompanyRow>? _companies;
  List<DocAlert> _alerts = const [];
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final companies = await loadCompanies();
      var alerts = const <DocAlert>[];
      try {
        alerts = await loadPlatformAlerts();
      } catch (_) {
        // Sin alertas no se cae la pantalla.
      }
      if (!mounted) return;
      setState(() {
        _companies = companies;
        _alerts = alerts;
        _failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _open(String companyId) async {
    await openCompanyPage(context, companyId: companyId, profile: widget.profile);
    await _load();
  }

  Future<void> _newCompany() async {
    final id = await openCompanyForm(context);
    if (id == null || !mounted) return;
    toast(context, 'Empresa creada. Ahora crea su administrador.');
    await _open(id);
  }

  @override
  Widget build(BuildContext context) {
    final list = _companies;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: const Text('Panel general'),
        actions: [
          IconButton(tooltip: 'Actualizar', icon: const Icon(Icons.refresh_rounded), onPressed: _load),
          IconButton(
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout_rounded),
            onPressed: () => supabase.auth.signOut(),
          ),
        ],
      ),
      body: list == null
          ? Center(
              child: _failed
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('No pudimos cargar las empresas.'),
                        const SizedBox(height: 12),
                        OutlinedButton(style: smallOutline(), onPressed: _load, child: const Text('Reintentar')),
                      ],
                    )
                  : const CircularProgressIndicator(color: AppColors.navy),
            )
          : AdminPage(onRefresh: _load, children: _content(list)),
    );
  }

  List<Widget> _content(List<CompanyRow> list) {
    final active = list.where((c) => c.active).length;
    final guards = list.fold<int>(0, (a, c) => a + c.guards);
    final urgent = _alerts.where((a) => a.urgent).length;
    return [
      Text(
        'Hola, ${widget.profile.firstName}',
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 4),
      const Text(
        'Tus empresas de seguridad. Toca una para ver sus administradores, crear usuarios o abrir su panel.',
        style: TextStyle(color: AppColors.muted),
      ),
      const SizedBox(height: 16),
      Panel(
        child: Wrap(
          spacing: 28,
          runSpacing: 12,
          children: [
            _stat('$active de ${list.length}', 'Empresas activas', AppColors.navy),
            _stat('$guards', 'Guardas activos', AppColors.navy),
            _stat('$urgent', 'Licencias o documentos con problema', urgent > 0 ? AppColors.danger : kOk),
          ],
        ),
      ),
      const SizedBox(height: 20),
      SectionHead(
        'Empresas (${list.length})',
        trailing: FilledButton.icon(
          style: smallBtn(),
          onPressed: _newCompany,
          icon: const Icon(Icons.add_business_rounded),
          label: const Text('Nueva empresa'),
        ),
      ),
      if (list.isEmpty)
        const Panel(child: EmptyState(Icons.business_outlined, 'Aún no hay empresas. Crea la primera.'))
      else
        for (final c in list)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Panel(
              onTap: () => _open(c.id),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.business_rounded, color: AppColors.navy),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(
                          'Código ${c.code} · ${c.guards} guardas · ${c.sites} sitios · ${c.clients} clientes',
                          style: const TextStyle(color: AppColors.muted, fontSize: 13),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (!c.active)
                              const Pill('Suspendida', AppColors.danger)
                            else
                              Pill(subscriptionLabel(c.subStatus), AppColors.navy),
                            _licensePill(c.licenseExpires),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                ],
              ),
            ),
          ),
      if (_alerts.isNotEmpty) ...[
        const SizedBox(height: 20),
        const SectionHead('Licencias y documentos de empresas'),
        for (final a in _alerts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Panel(
              onTap: () => _open(a.ownerId),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    a.urgent ? Icons.error_rounded : Icons.schedule_rounded,
                    color: a.urgent ? AppColors.danger : kWarn,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.ownerName, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('${a.typeName} · ${a.when}',
                            style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
      const SizedBox(height: 28),
      RolePreviewPicker(profile: widget.profile),
    ];
  }

  Widget _licensePill(DateTime? exp) {
    if (exp == null) return const Pill('Sin licencia DIGESSP', AppColors.danger);
    final n = daysFromToday(exp);
    if (n < 0) return const Pill('Licencia vencida', AppColors.danger);
    if (n <= 60) return Pill('Licencia vence en $n d', kWarn);
    return const Pill('Licencia vigente', kOk);
  }

  Widget _stat(String value, String label, Color color) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
          Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        ],
      );
}
