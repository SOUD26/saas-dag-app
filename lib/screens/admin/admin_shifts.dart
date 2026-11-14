import 'package:flutter/material.dart';

import '../../theme.dart';
import 'admin_data.dart';
import 'admin_ui.dart';

String shiftStatusLabel(AShift x) {
  switch (x.status) {
    case 'a_tiempo':
      return 'A tiempo';
    case 'tarde':
      return 'Tarde ${x.lateMinutes ?? 0} min';
    case 'programado':
      return 'Programado';
    case 'por_iniciar':
      return 'Por iniciar';
    case 'sin_llegada':
      return 'Sin llegada';
    case 'ausente':
      return 'Ausente';
    case 'cancelado':
      return 'Cancelado';
    default:
      return x.status;
  }
}

Color shiftStatusColor(String status) {
  switch (status) {
    case 'a_tiempo':
      return kOk;
    case 'tarde':
      return kWarn;
    case 'sin_llegada':
    case 'ausente':
      return AppColors.danger;
    case 'por_iniciar':
      return AppColors.navy;
    default:
      return AppColors.muted;
  }
}

String _hours(AShift x) => '${fmtTime(x.startsAt)}–${fmtTime(x.endsAt)}';

const _weekdays = ['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];

String _dayTitle(DateTime t) {
  final l = gtLocal(t);
  return '${_weekdays[l.weekday - 1]} ${fmtDay(t)}';
}

// ───────────────────────── Pestaña Turnos ─────────────────────────

class ShiftsView extends StatefulWidget {
  const ShiftsView({super.key, required this.d, required this.reload});
  final AdminData d;
  final Reload reload;

  @override
  State<ShiftsView> createState() => _ShiftsViewState();
}

class _ShiftsViewState extends State<ShiftsView> {
  bool _upcoming = true;

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    final t0 = todayStartUtc();
    final list = d.shifts
        .where((x) => _upcoming ? !x.startsAt.isBefore(t0) : x.startsAt.isBefore(t0))
        .toList()
      ..sort((a, b) => _upcoming
          ? a.startsAt.compareTo(b.startsAt)
          : b.startsAt.compareTo(a.startsAt));

    final children = <Widget>[
      SectionHead(
        'Turnos',
        trailing: FilledButton.icon(
          style: smallBtn(),
          onPressed: () {
            final cid = d.companyId;
            if (cid == null) {
              toast(context, 'Esta cuenta no tiene empresa asignada.');
              return;
            }
            showShiftDialog(context, d, cid, widget.reload);
          },
          icon: const Icon(Icons.add_rounded),
          label: const Text('Nuevo turno'),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Hoy y próximos'),
              selected: _upcoming,
              onSelected: (_) => setState(() => _upcoming = true),
            ),
            ChoiceChip(
              label: const Text('Historial'),
              selected: !_upcoming,
              onSelected: (_) => setState(() => _upcoming = false),
            ),
          ],
        ),
      ),
    ];

    if (list.isEmpty) {
      children.add(EmptyState(
        Icons.event_note_outlined,
        _upcoming
            ? 'No hay turnos programados. Crea el primero con "Nuevo turno".'
            : 'Aún no hay turnos en el historial.',
      ));
    } else {
      String? lastDay;
      for (final x in list) {
        final day = _dayTitle(x.startsAt);
        if (day != lastDay) {
          lastDay = day;
          children.add(Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text(day,
                style: const TextStyle(
                    fontWeight: FontWeight.w800, color: AppColors.navy)),
          ));
        }
        children.add(Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ShiftTile(d: d, x: x, reload: widget.reload),
        ));
      }
    }

    return AdminPage(onRefresh: widget.reload, children: children);
  }
}

class ShiftTile extends StatelessWidget {
  const ShiftTile({
    super.key,
    required this.d,
    required this.x,
    required this.reload,
    this.showGuard = true,
  });
  final AdminData d;
  final AShift x;
  final Reload reload;
  final bool showGuard;

  @override
  Widget build(BuildContext context) {
    return Panel(
      onTap: () => showShiftSheet(context, d, x, reload),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(
            fmtTimeIsNight(x.startsAt) ? Icons.nights_stay_rounded : Icons.wb_sunny_rounded,
            color: AppColors.navy,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  showGuard ? d.guardName(x.guardId) : d.siteName(x.siteId),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  showGuard
                      ? '${_hours(x)} · ${d.siteName(x.siteId)}'
                      : '${_dayTitle(x.startsAt)} · ${_hours(x)}',
                  style: const TextStyle(color: AppColors.muted, fontSize: 13),
                ),
              ],
            ),
          ),
          Pill(shiftStatusLabel(x), shiftStatusColor(x.status)),
        ],
      ),
    );
  }
}

/// Turno nocturno = empieza entre las 18:00 y las 05:59 (hora de Guatemala).
bool fmtTimeIsNight(DateTime t) {
  final h = gtLocal(t).hour;
  return h >= 18 || h < 6;
}

// ───────────────────────── Bitácora del guarda ─────────────────────────

class ShiftLogSection extends StatelessWidget {
  const ShiftLogSection({super.key, required this.d, required this.guardId});
  final AdminData d;
  final String guardId;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    final past = d.shiftsOf(guardId)
        .where((x) => !x.cancelled && x.startsAt.isBefore(now))
        .toList()
      ..sort((a, b) => b.startsAt.compareTo(a.startsAt));
    final onTime = past.where((x) => x.status == 'a_tiempo').length;
    final late = past.where((x) => x.status == 'tarde').length;
    final absent = past.where((x) => x.status == 'ausente').length;
    final lateMin = past
        .where((x) => x.status == 'tarde')
        .fold<int>(0, (a, x) => a + (x.lateMinutes ?? 0));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Bitácora de turnos (30 días)',
            style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (past.isEmpty)
          const Text('Sin turnos registrados.',
              style: TextStyle(color: AppColors.muted))
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              Pill('${past.length} turnos', AppColors.navy),
              Pill('$onTime a tiempo', kOk),
              Pill('$late tarde${late > 0 ? ' ($lateMin min)' : ''}', kWarn),
              Pill('$absent ausente${absent == 1 ? '' : 's'}', AppColors.danger),
            ],
          ),
          const SizedBox(height: 8),
          for (final x in past.take(10))
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                x.status == 'a_tiempo'
                    ? Icons.check_circle_rounded
                    : Icons.schedule_rounded,
                color: shiftStatusColor(x.status),
              ),
              title: Text('${_dayTitle(x.startsAt)} · ${_hours(x)}'),
              subtitle: Text(
                '${d.siteName(x.siteId)}'
                '${x.arrivedAt != null ? ' · llegó ${fmtTime(x.arrivedAt!)}' : ''}',
              ),
              trailing: Pill(shiftStatusLabel(x), shiftStatusColor(x.status)),
              onTap: () => showShiftSheet(context, d, x, () async {}),
            ),
        ],
      ],
    );
  }
}

// ───────────────────────── Detalle de un turno ─────────────────────────

Future<void> showShiftSheet(
  BuildContext context,
  AdminData d,
  AShift x,
  Reload reload,
) {
  Widget row(String k, String v) => Padding(
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

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    constraints: const BoxConstraints(maxWidth: 640),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(d.guardName(x.guardId),
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                ),
                Pill(shiftStatusLabel(x), shiftStatusColor(x.status)),
              ],
            ),
            const SizedBox(height: 12),
            row('Sitio', d.siteName(x.siteId)),
            row('Día', _dayTitle(x.startsAt)),
            row('Horario', _hours(x)),
            row('Tolerancia', '${x.grace} min'),
            row('Llegada', x.arrivedAt == null ? 'Sin registro' : fmtTime(x.arrivedAt!)),
            if (x.arrivedAt != null && (x.lateMinutes ?? 0) > 0)
              row('Diferencia', '${x.lateMinutes} min después de la hora'),
            row('Alertas', '${x.flags}'),
            if (x.notes != null && x.notes!.isNotEmpty) row('Notas', x.notes!),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: smallOutline(),
                    onPressed: () async {
                      Navigator.of(sheetCtx).pop();
                      final cid = d.companyId;
                      if (cid == null) return;
                      await showShiftDialog(context, d, cid, reload, existing: x);
                    },
                    child: const Text('Editar'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: smallBtn(),
                    onPressed: () async {
                      try {
                        await updateShift(x.id, {'cancelled': !x.cancelled});
                        await reload();
                        if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
                      } on ShiftError catch (e) {
                        if (sheetCtx.mounted) toast(sheetCtx, e.message);
                      } catch (_) {
                        if (sheetCtx.mounted) toast(sheetCtx, 'No se pudo guardar el cambio.');
                      }
                    },
                    child: Text(x.cancelled ? 'Reactivar turno' : 'Cancelar turno'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

// ───────────────────────── Crear / editar turno ─────────────────────────

Future<void> showShiftDialog(
  BuildContext context,
  AdminData d,
  String companyId,
  Reload reload, {
  AShift? existing,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ShiftDialog(
      d: d,
      companyId: companyId,
      reload: reload,
      existing: existing,
    ),
  );
}

class _ShiftDialog extends StatefulWidget {
  const _ShiftDialog({
    required this.d,
    required this.companyId,
    required this.reload,
    this.existing,
  });
  final AdminData d;
  final String companyId;
  final Reload reload;
  final AShift? existing;

  @override
  State<_ShiftDialog> createState() => _ShiftDialogState();
}

class _ShiftDialogState extends State<_ShiftDialog> {
  String? _guardId;
  String? _siteId;
  late DateTime _date; // día local de Guatemala (año, mes, día)
  TimeOfDay _start = const TimeOfDay(hour: 6, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 18, minute: 0);
  int _days = 1;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final x = widget.existing;
    final now = gtLocal(DateTime.now());
    _date = DateTime(now.year, now.month, now.day);
    if (x != null) {
      final s = gtLocal(x.startsAt);
      final e = gtLocal(x.endsAt);
      _guardId = x.guardId;
      _siteId = x.siteId;
      _date = DateTime(s.year, s.month, s.day);
      _start = TimeOfDay(hour: s.hour, minute: s.minute);
      _end = TimeOfDay(hour: e.hour, minute: e.minute);
    }
  }

  String _t(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickDate() async {
    final p = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(_date.year - 1),
      lastDate: DateTime(_date.year + 2),
    );
    if (p != null) setState(() => _date = DateTime(p.year, p.month, p.day));
  }

  Future<void> _pickTime(bool start) async {
    final p = await showTimePicker(
      context: context,
      initialTime: start ? _start : _end,
    );
    if (p != null) setState(() => start ? _start = p : _end = p);
  }

  Future<void> _save() async {
    if (_guardId == null || _siteId == null) {
      setState(() => _error = 'Elige el guarda y el sitio.');
      return;
    }
    final startMin = _start.hour * 60 + _start.minute;
    var dur = (_end.hour * 60 + _end.minute) - startMin;
    if (dur <= 0) dur += 24 * 60; // termina al día siguiente (turno nocturno)

    final rows = <Map<String, dynamic>>[];
    final n = widget.existing == null ? _days : 1;
    for (var i = 0; i < n; i++) {
      final day = DateTime(_date.year, _date.month, _date.day + i);
      final s = gtToUtc(day.year, day.month, day.day, _start.hour, _start.minute);
      rows.add({
        'company_id': widget.companyId,
        'site_id': _siteId,
        'guard_id': _guardId,
        'starts_at': s.toIso8601String(),
        'ends_at': s.add(Duration(minutes: dur)).toIso8601String(),
      });
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final x = widget.existing;
      if (x == null) {
        await insertShifts(rows);
      } else {
        await updateShift(x.id, {
          'site_id': _siteId,
          'guard_id': _guardId,
          'starts_at': rows.first['starts_at'],
          'ends_at': rows.first['ends_at'],
        });
      }
      await widget.reload();
      if (!mounted) return;
      Navigator.of(context).pop();
      toast(context, x == null ? 'Turno guardado.' : 'Turno actualizado.');
    } on ShiftError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'No se pudo guardar el turno.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final guards = widget.d.guards.where((g) => g.active || g.id == _guardId).toList();
    final sites = widget.d.sites.where((s) => s.active || s.id == _siteId).toList();
    final editing = widget.existing != null;
    final dateText =
        '${_date.day.toString().padLeft(2, '0')}/${_date.month.toString().padLeft(2, '0')}/${_date.year}';
    return AlertDialog(
      title: Text(editing ? 'Editar turno' : 'Nuevo turno'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                value: _guardId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Guarda'),
                items: [
                  for (final g in guards)
                    DropdownMenuItem(value: g.id, child: Text(g.name)),
                ],
                onChanged: _busy ? null : (v) => setState(() => _guardId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _siteId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Sitio'),
                items: [
                  for (final s in sites)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: _busy ? null : (v) => setState(() => _siteId = v),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: smallOutline(),
                onPressed: _busy ? null : _pickDate,
                icon: const Icon(Icons.calendar_today_rounded, size: 18),
                label: Text(editing ? 'Día: $dateText' : 'Desde el día: $dateText'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: smallOutline(),
                      onPressed: _busy ? null : () => _pickTime(true),
                      child: Text('Entra ${_t(_start)}'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      style: smallOutline(),
                      onPressed: _busy ? null : () => _pickTime(false),
                      child: Text('Sale ${_t(_end)}'),
                    ),
                  ),
                ],
              ),
              if (!editing) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  value: _days,
                  decoration: const InputDecoration(
                    labelText: 'Repetir',
                    helperText: 'Crea el mismo turno en días seguidos',
                  ),
                  items: [
                    for (final n in const [1, 2, 3, 4, 5, 6, 7, 14, 28])
                      DropdownMenuItem(
                        value: n,
                        child: Text(n == 1 ? 'Solo ese día' : '$n días seguidos'),
                      ),
                  ],
                  onChanged: _busy ? null : (v) => setState(() => _days = v ?? 1),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: AppColors.danger)),
              ],
            ],
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
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
