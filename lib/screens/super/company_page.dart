// Ficha de una empresa para el súper admin: sus administradores, crear usuarios y abrir su panel.
import 'package:flutter/material.dart';

import '../../models/profile.dart';
import '../../theme.dart';
import '../admin/admin_access.dart';
import '../admin/admin_data.dart';
import '../admin/admin_home.dart';
import '../admin/admin_ui.dart';
import '../admin/staff_file.dart';
import '../admin/staff_form.dart';
import 'company_form.dart';
import 'super_data.dart';

Future<void> openCompanyPage(BuildContext context, {required String companyId, required Profile profile}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => CompanyPage(companyId: companyId, profile: profile)),
  );
}

class CompanyPage extends StatefulWidget {
  const CompanyPage({super.key, required this.companyId, required this.profile});
  final String companyId;
  final Profile profile;

  @override
  State<CompanyPage> createState() => _CompanyPageState();
}

class _CompanyPageState extends State<CompanyPage> {
  CompanyInfo? _info;
  AdminData? _d;
  bool _failed = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await loadCompany(widget.companyId);
      final d = await loadAdminData(selectedCompanyId: widget.companyId);
      if (!mounted) return;
      setState(() {
        _info = info;
        _d = d;
        _failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _setActive(bool v) async {
    final info = _info;
    if (info == null) return;
    if (!v) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('¿Suspender ${info.name}?'),
          content: const Text(
            'Ninguno de sus usuarios (administradores, supervisores, guardas y clientes) podrá entrar '
            'hasta que la actives de nuevo. Sus datos se conservan.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Suspender'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      await setCompanyActive(info.id, v);
      await _load();
      if (mounted) toast(context, v ? 'Empresa activada.' : 'Empresa suspendida.');
    } on CompanyError catch (e) {
      if (mounted) toast(context, e.message);
    } catch (_) {
      if (mounted) toast(context, 'No se pudo cambiar el estado.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit() async {
    final info = _info;
    if (info == null) return;
    final id = await openCompanyForm(context, company: info);
    if (id != null) {
      await _load();
      if (mounted) toast(context, 'Empresa guardada.');
    }
  }

  void _openPanel() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          builder: (_) => AdminHome(
            profile: widget.profile,
            preview: true,
            initialCompanyId: widget.companyId,
          ),
        ))
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final d = _d;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: Text(info?.name ?? 'Empresa'),
        actions: [
          IconButton(tooltip: 'Actualizar', icon: const Icon(Icons.refresh_rounded), onPressed: _load),
        ],
      ),
      body: (info == null || d == null)
          ? Center(
              child: _failed
                  ? OutlinedButton(style: smallOutline(), onPressed: _load, child: const Text('Reintentar'))
                  : const CircularProgressIndicator(color: AppColors.navy),
            )
          : AdminPage(onRefresh: _load, children: _content(info, d)),
    );
  }

  List<Widget> _content(CompanyInfo info, AdminData d) {
    final admins = d.staff.where((s) => s.role == 'company_admin').toList();
    final guards = d.staff.where((s) => s.role == 'guard' && s.active).length;
    final sups = d.staff.where((s) => s.role == 'supervisor' && s.active).length;
    final lic = info.licenseExpires;
    final licDays = lic == null ? 0 : daysFromToday(lic);
    final licColor = lic == null || licDays < 0 ? AppColors.danger : (licDays <= 60 ? kWarn : kOk);
    final licText = lic == null
        ? 'Sin licencia registrada.'
        : (licDays < 0
            ? 'Licencia vencida desde ${fmtDate(lic)}.'
            : 'Licencia vigente hasta ${fmtDate(lic)}${licDays <= 60 ? ' (vence en $licDays días)' : ''}.');
    final companyAlerts = d.docAlerts.where((a) => a.ownerKind == 'company').toList();

    return [
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: AppColors.navy.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.business_rounded, color: AppColors.navy, size: 30),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(info.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                      if (info.legalName != null)
                        Text(info.legalName!, style: const TextStyle(color: AppColors.muted)),
                      Text(
                        [if (info.nit != null) 'NIT ${info.nit}', 'Código para guardas: ${info.code}'].join(' · '),
                        style: const TextStyle(color: AppColors.muted, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Empresa activa'),
              subtitle: Text(info.active
                  ? 'Sus usuarios pueden entrar a la app.'
                  : 'Suspendida: nadie de esta empresa puede entrar.'),
              value: info.active,
              onChanged: _busy ? null : _setActive,
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  style: smallBtn(),
                  onPressed: _openPanel,
                  icon: const Icon(Icons.dashboard_rounded),
                  label: const Text('Abrir panel de la empresa'),
                ),
                OutlinedButton.icon(
                  style: smallOutline(),
                  onPressed: () => openStaffForm(context, d: d, companyId: info.id, reload: _load),
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  label: const Text('Nuevo usuario'),
                ),
                OutlinedButton.icon(
                  style: smallOutline(),
                  onPressed: _edit,
                  icon: const Icon(Icons.edit_rounded),
                  label: const Text('Editar datos'),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      SectionHead(
        'Administradores (${admins.length})',
        trailing: FilledButton.icon(
          style: smallBtn(),
          onPressed: () => openStaffForm(
            context,
            d: d,
            companyId: info.id,
            reload: _load,
            initialRole: 'company_admin',
          ),
          icon: const Icon(Icons.admin_panel_settings_rounded),
          label: const Text('Nuevo administrador'),
        ),
      ),
      if (admins.isEmpty)
        const Panel(
          child: EmptyState(
            Icons.admin_panel_settings_outlined,
            'Esta empresa aún no tiene administrador. Créalo para que pueda entrar y manejar su personal.',
          ),
        )
      else
        for (final a in admins)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Panel(
              onTap: () => showAccessSheet(context, d, a, _load),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  PersonAvatar(url: d.avatarUrls[a.id], icon: Icons.admin_panel_settings_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(a.login ?? 'Sin correo', style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                      ],
                    ),
                  ),
                  if (!a.active) const Pill('Inactivo', AppColors.muted),
                ],
              ),
            ),
          ),
      const SizedBox(height: 20),
      const SectionHead('Resumen'),
      Panel(
        child: Wrap(
          spacing: 24,
          runSpacing: 12,
          children: [
            _stat('${d.sites.where((s) => s.active).length}', 'Sitios'),
            _stat('$guards', 'Guardas'),
            _stat('$sups', 'Supervisores'),
            _stat('${d.clients.where((c) => c.active).length}', 'Clientes'),
          ],
        ),
      ),
      const SizedBox(height: 20),
      const SectionHead('Licencia DIGESSP y documentos'),
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(licText, style: TextStyle(fontWeight: FontWeight.w700, color: licColor)),
            if (info.licenseNumber != null)
              Text('Número: ${info.licenseNumber}', style: const TextStyle(color: AppColors.muted)),
            for (final x in companyAlerts.where((a) => a.typeKey != 'digessp_license'))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '• ${x.typeName}: ${x.when}',
                  style: TextStyle(color: x.urgent ? AppColors.danger : kWarn),
                ),
              ),
            const SizedBox(height: 6),
            TextButton(onPressed: _edit, child: const Text('Registrar o renovar licencia')),
          ],
        ),
      ),
      const SizedBox(height: 20),
      const SectionHead('Suscripción'),
      Panel(
        child: Column(
          children: [
            _row('Estado', subscriptionLabel(info.subStatus)),
            _row('Plan', info.plan ?? '—'),
            _row('Cuota mensual',
                info.fee == null ? '—' : '${info.currency == 'USD' ? r'$' : 'Q'} ${info.fee!.toStringAsFixed(2)}'),
            _row('Día de cobro', info.billingDay?.toString() ?? '—'),
            _row('Inicio', info.startedOn == null ? '—' : fmtDate(info.startedOn!)),
            _row('Fin de prueba', info.trialEndsOn == null ? '—' : fmtDate(info.trialEndsOn!)),
            if (info.notes != null) _row('Notas', info.notes!),
          ],
        ),
      ),
      const SizedBox(height: 20),
      const SectionHead('Contacto'),
      Panel(
        child: Column(
          children: [
            _row('Representante', info.legalRep ?? '—'),
            _row('Teléfono', info.phone ?? '—'),
            _row('Correo', info.email ?? '—'),
            _row(
              'Dirección',
              [info.address, info.municipality, info.department].whereType<String>().join(', ').isEmpty
                  ? '—'
                  : [info.address, info.municipality, info.department].whereType<String>().join(', '),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _stat(String value, String label) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        ],
      );

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 120, child: Text(k, style: const TextStyle(color: AppColors.muted, fontSize: 13))),
            Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
          ],
        ),
      );
}
