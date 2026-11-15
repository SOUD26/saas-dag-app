import 'package:flutter/material.dart';

import '../../theme.dart';
import 'admin_data.dart';
import 'admin_access.dart';
import 'admin_shifts.dart';
import 'admin_ui.dart';
import 'staff_form.dart';

typedef Reload = Future<void> Function();

Future<void> _sheet(BuildContext context, Widget child) {
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
        child: child,
      ),
    ),
  );
}

Widget _row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(k, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
          ),
          Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
        ],
      ),
    );

// ───────────────────────── Bandera ─────────────────────────

Future<void> showFlagSheet(
  BuildContext context,
  AdminData d,
  AVerif v,
  Reload reload,
) =>
    _sheet(context, _FlagBody(d: d, v: v, reload: reload));

class _FlagBody extends StatefulWidget {
  const _FlagBody({required this.d, required this.v, required this.reload});
  final AdminData d;
  final AVerif v;
  final Reload reload;

  @override
  State<_FlagBody> createState() => _FlagBodyState();
}

class _FlagBodyState extends State<_FlagBody> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await widget.reload();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      toast(context, 'No se pudo guardar. Intenta de nuevo.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final v = widget.v;
    final repeat = v.guardId != null && d.repeatGuards.contains(v.guardId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Icon(Icons.flag_rounded, color: AppColors.danger),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Alerta',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            Pill(Outcome.label(v.outcome), outcomeColor(v.outcome)),
          ],
        ),
        const SizedBox(height: 14),
        _row('Guarda', d.guardName(v.guardId)),
        _row('Sitio', d.siteName(v.siteId)),
        _row('Cuándo', fmtWhen(v.createdAt)),
        _row('Motivo', v.reason ?? 'Sin motivo registrado'),
        if (v.distance != null) _row('Distancia', '${v.distance!.round()} m del centro'),
        if (v.score != null) _row('Coincidencia', v.score!.toStringAsFixed(2)),
        if (repeat) ...[
          const SizedBox(height: 8),
          Pill('Reincidente · ${d.flagCount(v.guardId!)} alertas en 7 días', AppColors.danger),
        ],
        const SizedBox(height: 18),
        if (v.reviewed) ...[
          Text(
            'Revisada el ${fmtWhen(v.reviewedAt!)}',
            style: const TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            style: smallOutline(),
            onPressed: _busy ? null : () => _run(() => reopenVerif(v.id)),
            icon: const Icon(Icons.undo_rounded),
            label: const Text('Reabrir'),
          ),
        ] else ...[
          const Text('¿Cómo la resuelves?',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final o in Outcome.all)
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    backgroundColor: outcomeColor(o),
                  ),
                  onPressed: _busy ? null : () => _run(() => reviewVerif(v.id, o)),
                  child: Text(Outcome.label(o)),
                ),
            ],
          ),
        ],
        if (v.guardId != null) ...[
          const SizedBox(height: 14),
          TextButton.icon(
            onPressed: () {
              final g = d.guard(v.guardId);
              if (g != null) showGuardSheet(context, d, g, widget.reload);
            },
            icon: const Icon(Icons.person_search_rounded),
            label: const Text('Ver historial del guarda'),
          ),
        ],
      ],
    );
  }
}

// ───────────────────────── Sitio ─────────────────────────

Future<void> showSiteSheet(
  BuildContext context,
  AdminData d,
  ASite s,
  Reload reload,
) {
  final flags = d.verifs.where((v) => v.flagged && v.siteId == s.id).toList();
  final guards = d.guardsAt(s.id);
  return _sheet(
    context,
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Icon(Icons.place_rounded, color: AppColors.navy),
            const SizedBox(width: 8),
            Expanded(
              child: Text(s.name,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            if (!s.active) const Pill('Inactivo', AppColors.muted),
          ],
        ),
        const SizedBox(height: 12),
        _row('Cliente', d.clientName(s.clientId)),
        _row('Perímetro', '${s.radius} m'),
        if (s.hasCoords)
          _row('Ubicación', '${s.lat!.toStringAsFixed(5)}, ${s.lng!.toStringAsFixed(5)}'),
        _row(
          'Guardas',
          guards.isEmpty ? 'Ninguno asignado' : guards.map((g) => g.name).join(', '),
        ),
        const SizedBox(height: 14),
        Text('Alertas (7 días): ${flags.length}',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        if (flags.isEmpty)
          const Text('Sin alertas.', style: TextStyle(color: AppColors.muted))
        else
          for (final v in flags.take(6))
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(d.guardName(v.guardId)),
              subtitle: Text('${fmtWhen(v.createdAt)} · ${v.reason ?? ''}'),
              trailing: Pill(Outcome.label(v.outcome), outcomeColor(v.outcome)),
              onTap: () => showFlagSheet(context, d, v, reload),
            ),
      ],
    ),
  );
}

// ───────────────────────── Guarda ─────────────────────────

Future<void> showGuardSheet(
  BuildContext context,
  AdminData d,
  AGuard g,
  Reload reload,
) {
  final mine = d.verifs.where((v) => v.guardId == g.id).toList();
  final sites = (d.assign[g.id] ?? const <String>{}).map(d.siteName).toList();
  return _sheet(
    context,
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            PersonAvatar(url: d.avatarUrls[g.id], icon: Icons.badge_rounded, radius: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Text(g.name,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            if (!g.active) const Pill('Inactivo', AppColors.muted),
          ],
        ),
        const SizedBox(height: 12),
        _row('Teléfono', d.staffById(g.id)?.phone ?? 'Sin teléfono'),
        _row('Sitios', sites.isEmpty ? 'Sin sitios asignados' : sites.join(', ')),
        _row('Verificaciones', '${mine.length} en 7 días'),
        _row('Alertas', '${d.flagCount(g.id)} en 7 días'),
        if (d.alertsOf(g.id).isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('Documentos', style: TextStyle(fontWeight: FontWeight.w700)),
          for (final a in d.alertsOf(g.id))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '• ${a.typeName}: ${a.when}',
                style: TextStyle(color: a.urgent ? AppColors.danger : kWarn),
              ),
            ),
        ],
        const SizedBox(height: 14),
        ShiftLogSection(d: d, guardId: g.id),
        const SizedBox(height: 14),
        if (d.staffById(g.id) != null)
          Builder(
            builder: (ctx) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (d.companyId != null)
                  FilledButton.icon(
                    style: smallBtn(),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      openStaffForm(context,
                          d: d, companyId: d.companyId!, reload: reload, person: d.staffById(g.id));
                    },
                    icon: const Icon(Icons.badge_outlined),
                    label: const Text('Ficha y documentos'),
                  ),
                OutlinedButton.icon(
                  style: smallOutline(),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    showAccessSheet(context, d, d.staffById(g.id)!, reload);
                  },
                  icon: const Icon(Icons.lock_person_rounded),
                  label: const Text('Accesos y contraseña'),
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        const Text('Últimos movimientos', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        if (mine.isEmpty)
          const Text('Sin movimientos.', style: TextStyle(color: AppColors.muted))
        else
          for (final v in mine.take(8))
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                v.flagged ? Icons.flag_rounded : Icons.check_circle_rounded,
                color: v.flagged ? AppColors.danger : kOk,
              ),
              title: Text(d.siteName(v.siteId)),
              subtitle: Text(
                v.flagged
                    ? '${fmtWhen(v.createdAt)} · ${v.reason ?? ''}'
                    : fmtWhen(v.createdAt),
              ),
              onTap: v.flagged ? () => showFlagSheet(context, d, v, reload) : null,
            ),
      ],
    ),
  );
}

// ───────────────────────── Formularios ─────────────────────────

Future<void> showNewClientDialog(
  BuildContext context,
  String companyId,
  Reload reload,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _NewClientDialog(companyId: companyId, reload: reload),
  );
}

class _NewClientDialog extends StatefulWidget {
  const _NewClientDialog({required this.companyId, required this.reload});
  final String companyId;
  final Reload reload;

  @override
  State<_NewClientDialog> createState() => _NewClientDialogState();
}

class _NewClientDialogState extends State<_NewClientDialog> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Escribe el nombre del cliente.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await createClient(widget.companyId, name);
      await widget.reload();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'No se pudo crear el cliente.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nuevo cliente'),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'Nombre del cliente',
            errorText: _error,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: smallBtn(),
          onPressed: _busy ? null : _save,
          child: const Text('Crear'),
        ),
      ],
    );
  }
}

// ───────────────────────── Nuevo usuario ─────────────────────────

/// Alta de usuario: abre el formulario completo (cuenta + ficha + documentos + foto).
Future<void> showNewUserDialog(
  BuildContext context,
  AdminData d,
  String companyId,
  Reload reload,
) =>
    openStaffForm(context, d: d, companyId: companyId, reload: reload);
