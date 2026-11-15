import 'package:flutter/material.dart';

import '../../theme.dart';
import 'admin_data.dart';
import 'admin_sheets.dart';
import 'admin_ui.dart';
import 'staff_file.dart' show DocAlert;
import 'staff_form.dart';

const _roleOrder = ['guard', 'supervisor', 'company_admin', 'client', 'resident'];

const _rolePlural = <String, String>{
  'guard': 'Guardas',
  'supervisor': 'Supervisores',
  'company_admin': 'Administradores',
  'client': 'Clientes',
  'resident': 'Usuarios',
};

IconData _roleIcon(String role) {
  switch (role) {
    case 'guard':
      return Icons.badge_rounded;
    case 'supervisor':
      return Icons.visibility_rounded;
    case 'company_admin':
      return Icons.admin_panel_settings_rounded;
    case 'client':
      return Icons.apartment_rounded;
    default:
      return Icons.person_rounded;
  }
}

// ───────────────────────── Pestaña Personal ─────────────────────────

class PersonnelView extends StatefulWidget {
  const PersonnelView({super.key, required this.d, required this.reload});
  final AdminData d;
  final Reload reload;

  @override
  State<PersonnelView> createState() => _PersonnelViewState();
}

class _PersonnelViewState extends State<PersonnelView> {
  String _role = 'guard';

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final people = d.staff.where((x) => x.role == _role).toList();
    final today = d.verifiedTodayGuards;
    final repeat = d.repeatGuards;

    return AdminPage(
      onRefresh: widget.reload,
      children: [
        SectionHead(
          'Personal (${d.staff.length})',
          trailing: FilledButton.icon(
            style: smallBtn(),
            onPressed: () {
              final cid = d.companyId;
              if (cid == null) {
                toast(context, 'Esta cuenta no tiene empresa asignada.');
                return;
              }
              showNewUserDialog(context, d, cid, widget.reload);
            },
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: const Text('Nuevo usuario'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final r in _roleOrder)
                ChoiceChip(
                  label: Text(
                      '${_rolePlural[r]} (${d.staff.where((x) => x.role == r).length})'),
                  selected: _role == r,
                  onSelected: (_) => setState(() => _role = r),
                ),
            ],
          ),
        ),
        if (people.isEmpty)
          EmptyState(
            _roleIcon(_role),
            'Aún no hay ${_rolePlural[_role]!.toLowerCase()}. Crea el primero con "Nuevo usuario".',
          )
        else
          for (final x in people)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Panel(
                onTap: () {
                  final g = d.guard(x.id);
                  if (x.role == 'guard' && g != null) {
                    showGuardSheet(context, d, g, widget.reload);
                  } else {
                    showAccessSheet(context, d, x, widget.reload);
                  }
                },
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    PersonAvatar(url: d.avatarUrls[x.id], icon: _roleIcon(x.role)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(x.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                          Text(
                            x.role == 'guard'
                                ? '${(d.assign[x.id] ?? const <String>{}).length} sitios · ${d.flagCount(x.id)} alertas en 7 días'
                                : (x.login ?? roleLabels[x.role] ?? x.role),
                            style: const TextStyle(color: AppColors.muted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    if (x.active && d.alertsOf(x.id).isNotEmpty) ...[
                      _DocBadge(alerts: d.alertsOf(x.id)),
                      const SizedBox(width: 6),
                    ],
                    if (!x.active)
                      const Pill('Inactivo', AppColors.muted)
                    else if (x.role == 'guard' && repeat.contains(x.id))
                      const Pill('Reincidente', AppColors.danger)
                    else if (x.role == 'guard' && today.contains(x.id))
                      const Pill('Verificado hoy', kOk)
                    else if (x.role == 'guard')
                      const Pill('Sin verificar hoy', kWarn),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

// ───────────────────────── Accesos de una persona ─────────────────────────

Future<void> showAccessSheet(
  BuildContext context,
  AdminData d,
  AStaff s,
  Reload reload,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    constraints: const BoxConstraints(maxWidth: 640),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: _AccessBody(d: d, s: s, reload: reload),
      ),
    ),
  );
}

class _AccessBody extends StatefulWidget {
  const _AccessBody({required this.d, required this.s, required this.reload});
  final AdminData d;
  final AStaff s;
  final Reload reload;

  @override
  State<_AccessBody> createState() => _AccessBodyState();
}

class _AccessBodyState extends State<_AccessBody> {
  late bool _active = widget.s.active;
  late final Set<String> _perms = {...(widget.d.userPerms[widget.s.id] ?? const <String>{})};
  bool _busy = false;

  bool get _isSelf => widget.s.id == widget.d.myId;

  /// Un administrador de empresa no toca a otros administradores; el súper admin sí.
  bool get _canManage =>
      !_isSelf && (widget.d.isSuper || widget.s.role != 'company_admin');

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await widget.reload();
    } on UserCreateError catch (e) {
      if (mounted) toast(context, e.message);
    } catch (_) {
      if (mounted) toast(context, 'No se pudo guardar el cambio.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _password() async {
    final pw = await showDialog<String>(
      context: context,
      builder: (_) => const _PasswordDialog(),
    );
    if (pw == null || !mounted) return;
    await _run(() async {
      await resetUserPassword(widget.s.id, pw);
      if (mounted) toast(context, 'Contraseña cambiada.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final s = widget.s;
    final cid = d.companyId;
    final applicable = d.perms.where((p) => p.grantableTo.contains(s.role)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            PersonAvatar(url: d.avatarUrls[s.id], icon: _roleIcon(s.role), radius: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Text(s.name,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            Pill(roleLabels[s.role] ?? s.role, AppColors.navy),
          ],
        ),
        if (s.login != null) ...[
          const SizedBox(height: 4),
          Text(s.login!, style: const TextStyle(color: AppColors.muted)),
        ],
        if (s.phone != null) ...[
          const SizedBox(height: 2),
          Text('Tel. ${s.phone}', style: const TextStyle(color: AppColors.muted)),
        ],
        if (cid != null) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            style: smallBtn(),
            onPressed: () {
              final nav = Navigator.of(context);
              nav.pop();
              nav.push(MaterialPageRoute<void>(
                builder: (_) => StaffFormPage(d: d, companyId: cid, reload: widget.reload, person: s),
              ));
            },
            icon: const Icon(Icons.badge_outlined),
            label: Text(s.role == 'client' || s.role == 'resident' ? 'Datos y teléfono' : 'Ficha y documentos'),
          ),
        ],
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Cuenta activa'),
          subtitle: Text(_active
              ? 'Puede entrar a la app.'
              : 'No puede entrar. Su historial se conserva.'),
          value: _active,
          onChanged: (_busy || !_canManage)
              ? null
              : (v) => _run(() async {
                    await setUserActive(s.id, v);
                    if (mounted) setState(() => _active = v);
                  }),
        ),
        const Divider(),
        const Text('Funciones extra', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        if (applicable.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Este rol no tiene funciones extra para otorgar.',
              style: TextStyle(color: AppColors.muted),
            ),
          )
        else
          for (final p in applicable)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(p.label),
              subtitle: Text('${p.module} · ${p.description}'),
              value: _perms.contains(p.key),
              onChanged: (_busy || !_canManage || cid == null)
                  ? null
                  : (v) => _run(() async {
                        if (v) {
                          await grantPermission(s.id, p.key, cid);
                        } else {
                          await revokePermission(s.id, p.key);
                        }
                        if (mounted) {
                          setState(() => v ? _perms.add(p.key) : _perms.remove(p.key));
                        }
                      }),
            ),
        const Divider(),
        OutlinedButton.icon(
          style: smallOutline(),
          onPressed: (_busy || !_canManage) ? null : _password,
          icon: const Icon(Icons.key_rounded),
          label: const Text('Cambiar contraseña'),
        ),
        if (!_canManage)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _isSelf
                  ? 'Esta es tu propia cuenta: no puedes cambiar tus accesos aquí.'
                  : 'Solo el súper administrador puede cambiar los accesos de un administrador.',
              style: const TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          ),
      ],
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _pw = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nueva contraseña'),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _pw,
          autofocus: true,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Contraseña',
            helperText: 'Mínimo 8 caracteres. Entrégasela a la persona.',
            errorText: _error,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: smallBtn(),
          onPressed: () {
            if (_pw.text.length < 8) {
              setState(() => _error = 'Mínimo 8 caracteres.');
              return;
            }
            Navigator.of(context).pop(_pw.text);
          },
          child: const Text('Cambiar'),
        ),
      ],
    );
  }
}

/// Ícono de documentos en la lista de personal: rojo si hay vencidos o faltantes, ámbar si solo por vencer.
class _DocBadge extends StatelessWidget {
  const _DocBadge({required this.alerts});
  final List<DocAlert> alerts;

  @override
  Widget build(BuildContext context) {
    final urgent = alerts.any((a) => a.urgent);
    return Tooltip(
      message: urgent ? 'Documentos vencidos o faltantes' : 'Documentos por vencer',
      child: Icon(
        Icons.assignment_late_rounded,
        size: 22,
        color: urgent ? AppColors.danger : kWarn,
      ),
    );
  }
}
