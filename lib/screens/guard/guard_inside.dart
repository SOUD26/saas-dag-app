import 'package:flutter/material.dart';

import 'guard_session.dart';
import 'guard_store.dart';
import 'guard_ui.dart';
import 'readers.dart' show fmtPlate, newId;

/// Quién está dentro. Un toque en "Salió" y listo.
class GuardInsidePage extends StatefulWidget {
  const GuardInsidePage({super.key, required this.session});
  final GuardSession session;

  @override
  State<GuardInsidePage> createState() => _GuardInsidePageState();
}

class _GuardInsidePageState extends State<GuardInsidePage> {
  late List<InsideEntry> _list;
  final _q = TextEditingController();

  String get _siteId => widget.session.siteId ?? '';

  @override
  void initState() {
    super.initState();
    _list = widget.session.store.inside(_siteId);
    _refresh();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final l = await widget.session.refreshInside();
    if (mounted) setState(() => _list = l);
  }

  String _title(InsideEntry e) =>
      e.plate != null && e.plate!.isNotEmpty ? fmtPlate(e.plate) : (e.personName ?? 'Persona');

  Future<void> _exit(InsideEntry e) async {
    final ok = await askYesNo(context, '¿Salió ${_title(e)}?', yes: 'Sí, salió', no: 'No', color: gNavy);
    if (!ok || !mounted) return;
    final s = widget.session;
    final now = DateTime.now();
    await s.enqueue(GuardOp(
      id: newId(),
      kind: 'exit',
      label: 'Salida ${_title(e)}',
      at: now,
      params: {'p_id': e.id, 'p_happened_at': now.toUtc().toIso8601String(), 'p_device_id': null},
    ));
    await s.store.removeInside(_siteId, e.id);
    setState(() => _list.removeWhere((x) => x.id == e.id));
    await s.sync();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Salida guardada ${hhmm(now)} · ${_title(e)}', style: const TextStyle(fontSize: 18)),
      backgroundColor: gGreen,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.text.trim().toUpperCase().replaceAll('-', '');
    final shown = q.isEmpty
        ? _list
        : _list
            .where((e) =>
                (e.plate ?? '').toUpperCase().contains(q) ||
                (e.personName ?? '').toUpperCase().contains(q) ||
                (e.companyName ?? '').toUpperCase().contains(q))
            .toList();
    return GuardPage(
      title: 'Dentro ahora (${_list.length})',
      actions: [IconButton(tooltip: 'Actualizar', onPressed: _refresh, icon: const Icon(Icons.refresh_rounded, size: 30))],
      children: [
        if (_list.length > 5) ...[
          TextField(
            controller: _q,
            textCapitalization: TextCapitalization.characters,
            style: const TextStyle(fontSize: 21),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Buscar placa o nombre'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
        ],
        if (_list.isEmpty)
          const GuardCard(child: Text('No hay nadie dentro.', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700))),
        for (final e in shown)
          GuardCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      e.kind == 'pedestrian'
                          ? Icons.directions_walk_rounded
                          : (e.kind == 'motorcycle' ? Icons.two_wheeler_rounded : Icons.directions_car_rounded),
                      size: 34,
                      color: gNavy,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(_title(e),
                          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 1)),
                    ),
                    if (!e.synced)
                      const Icon(Icons.cloud_off_rounded, color: gAmber, size: 26),
                  ],
                ),
                if (e.plate != null && e.personName != null)
                  Text(e.personName!, style: const TextStyle(fontSize: 19)),
                Text(
                  [
                    if (e.companyName != null && e.companyName!.isNotEmpty) e.companyName!,
                    if (e.destination != null && e.destination!.isNotEmpty) 'va a ${e.destination}',
                    if (e.docLast4 != null) 'doc. ****${e.docLast4}',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 17, color: gSoft),
                ),
                Text('Entró ${dayHhmm(e.enteredAt)} · ${sinceText(e.enteredAt)}',
                    style: const TextStyle(fontSize: 17, color: gSoft)),
                const SizedBox(height: 10),
                GuardMainButton(label: 'Salió', color: gNavy, onTap: () => _exit(e)),
              ],
            ),
          ),
      ],
    );
  }
}
