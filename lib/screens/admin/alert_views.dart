import 'package:flutter/material.dart';

import '../../theme.dart';
import '../sites/site_data.dart' show sevColor, sevHint, sevLabel;
import 'admin_data.dart';
import 'admin_sheets.dart' show Reload;
import 'admin_ui.dart';

IconData _sourceIcon(String s) {
  switch (s) {
    case 'handover':
      return Icons.inventory_2_rounded;
    case 'round':
      return Icons.qr_code_2_rounded;
    case 'panic':
      return Icons.warning_rounded;
    case 'verification':
      return Icons.how_to_reg_rounded;
  }
  return Icons.flag_rounded;
}

/// Fila de alerta (panel y bandeja). El color dice qué tan urgente es.
class AlertTile extends StatelessWidget {
  const AlertTile({super.key, required this.d, required this.a, required this.reload});
  final AdminData d;
  final AAlert a;
  final Reload reload;

  @override
  Widget build(BuildContext context) {
    final color = sevColor(a.severity);
    final repeat = a.guardId != null && d.repeatGuards.contains(a.guardId);
    final firstLine = (a.detail ?? '').split('\n').first;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Panel(
        onTap: () => showAlertSheet(context, d, a, reload),
        padding: EdgeInsets.zero,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 6, color: a.pending ? color : AppColors.line),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Icon(_sourceIcon(a.source), color: a.pending ? color : AppColors.muted),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                        '${d.guardName(a.guardId)} · ${d.siteName(a.siteId)} · ${fmtWhen(a.createdAt)}',
                        style: const TextStyle(color: AppColors.muted, fontSize: 13),
                      ),
                      if (firstLine.isNotEmpty)
                        Text(firstLine, style: const TextStyle(fontSize: 13), maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    a.pending ? Pill(sevLabel(a.severity), color) : Pill(Outcome.label(a.outcome), outcomeColor(a.outcome)),
                    if (repeat) ...[
                      const SizedBox(height: 6),
                      const Pill('Reincidente', AppColors.danger),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bandeja de alertas · últimos 7 días.
class AlertsView extends StatelessWidget {
  const AlertsView({
    super.key,
    required this.d,
    required this.filter,
    required this.onFilter,
    required this.reload,
  });

  final AdminData d;
  final String filter; // pending | red | orange | yellow | repeat | reviewed | all
  final ValueChanged<String> onFilter;
  final Reload reload;

  @override
  Widget build(BuildContext context) {
    final repeat = d.repeatGuards;
    final pending = d.pendingAlerts;
    int count(String s) => pending.where((a) => a.severity == s).length;
    final List<AAlert> list;
    switch (filter) {
      case 'pending':
        list = pending;
        break;
      case 'red':
      case 'orange':
      case 'yellow':
        list = pending.where((a) => a.severity == filter).toList();
        break;
      case 'repeat':
        list = d.alerts.where((a) => a.guardId != null && repeat.contains(a.guardId)).toList();
        break;
      case 'reviewed':
        list = d.alerts.where((a) => !a.pending).toList();
        break;
      default:
        list = d.alerts;
    }

    final options = <String, String>{
      'pending': 'Pendientes (${pending.length})',
      'red': 'Rojas (${count('red')})',
      'orange': 'Naranjas (${count('orange')})',
      'yellow': 'Amarillas (${count('yellow')})',
      'repeat': 'Reincidentes',
      'reviewed': 'Revisadas',
      'all': 'Todas (${d.alerts.length})',
    };

    return AdminPage(
      onRefresh: reload,
      children: [
        const SectionHead('Alertas · últimos 7 días'),
        const Text(
          'Roja: actuar ya · Naranja: revisar hoy · Amarilla: revisar cuando se pueda.',
          style: TextStyle(color: AppColors.muted, fontSize: 13),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in options.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: filter == e.key,
                onSelected: (_) => onFilter(e.key),
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (list.isEmpty)
          EmptyState(
            filter == 'pending' ? Icons.verified_rounded : Icons.flag_outlined,
            filter == 'pending' ? 'Nada pendiente. Todo revisado.' : 'No hay alertas con este filtro.',
          )
        else
          for (final a in list) AlertTile(d: d, a: a, reload: reload),
      ],
    );
  }
}

/// Detalle de una alerta y su revisión (solo el administrador revisa).
Future<void> showAlertSheet(BuildContext context, AdminData d, AAlert a, Reload reload) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    constraints: const BoxConstraints(maxWidth: 640),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => SafeArea(child: _AlertSheet(d: d, a: a, reload: reload)),
  );
}

class _AlertSheet extends StatefulWidget {
  const _AlertSheet({required this.d, required this.a, required this.reload});
  final AdminData d;
  final AAlert a;
  final Reload reload;

  @override
  State<_AlertSheet> createState() => _AlertSheetState();
}

class _AlertSheetState extends State<_AlertSheet> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
      await widget.reload();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      toast(context, 'No se pudo guardar la revisión.');
    }
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 110, child: Text(k, style: const TextStyle(color: AppColors.muted, fontSize: 13))),
            Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final a = widget.a;
    final d = widget.d;
    final color = sevColor(a.severity);
    AVerif? verif;
    if (a.source == 'verification') {
      for (final v in d.verifs) {
        if (v.id == a.sourceId) verif = v;
      }
    }
    final lines = (a.detail ?? '').split('\n').where((x) => x.trim().isNotEmpty).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(_sourceIcon(a.source), color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(a.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              ),
              Pill(sevLabel(a.severity), color),
            ],
          ),
          const SizedBox(height: 4),
          Text(sevHint(a.severity), style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          _row(a.source == 'handover' ? 'Lo reportó' : 'Guarda', d.guardName(a.guardId)),
          if (a.relatedGuardId != null)
            _row(a.source == 'handover' ? 'Turno anterior' : 'Relacionado', d.guardName(a.relatedGuardId)),
          _row('Sitio', d.siteName(a.siteId)),
          _row('Cuándo', fmtWhen(a.createdAt)),
          if (verif?.distance != null) _row('Distancia', '${verif!.distance!.round()} m del sitio'),
          if (verif?.score != null) _row('Parecido', '${(verif!.score! * 100).round()} %'),
          if (lines.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text('Detalle', style: TextStyle(color: AppColors.muted, fontSize: 13)),
            const SizedBox(height: 4),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('• $l'),
              ),
          ],
          if (a.source == 'handover') ...[
            const SizedBox(height: 10),
            const Text(
              'En un relevo que no cuadra, el que recibió sin reclamar queda como responsable. '
              'Decide con el supervisor quién responde.',
              style: TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          ],
          const SizedBox(height: 18),
          if (!a.pending) ...[
            _row('Revisión', Outcome.label(a.outcome)),
            if ((a.note ?? '').isNotEmpty) _row('Nota', a.note!),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: smallOutline(),
              onPressed: _busy ? null : () => _run(() => reopenAlert(a.id)),
              icon: const Icon(Icons.undo_rounded),
              label: const Text('Reabrir'),
            ),
          ] else ...[
            const Text('¿Cómo la clasificas?', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final o in Outcome.all)
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: outcomeColor(o),
                      minimumSize: const Size(0, 44),
                    ),
                    onPressed: _busy ? null : () => _run(() => reviewAlert(a.id, o)),
                    child: Text(Outcome.label(o)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
