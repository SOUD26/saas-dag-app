import 'package:flutter/material.dart';

import '../../supabase.dart';
import 'guard_session.dart';
import 'guard_store.dart';
import 'guard_ui.dart';
import 'readers.dart' show newId;

/// Relevo: el que entra recibe y el que sale entrega. Cada uno marca por su lado, sin ver lo que
/// marcó el otro ni cuántas unidades debería haber.
class GuardChecklistPage extends StatefulWidget {
  const GuardChecklistPage({
    super.key,
    required this.session,
    required this.post,
    required this.kind,
    this.ordersSeen = false,
  });

  final GuardSession session;
  final Map<String, dynamic> post;
  final String kind; // reception | delivery
  final bool ordersSeen;

  @override
  State<GuardChecklistPage> createState() => _GuardChecklistPageState();
}

class _Mark {
  String? status; // ok | damaged | missing
  int? counted;
  String note = '';
}

class _GuardChecklistPageState extends State<GuardChecklistPage> {
  late List<Map<String, dynamic>> _items;
  final Map<String, _Mark> _marks = {};
  bool _busy = false;

  bool get _reception => widget.kind == 'reception';
  String get _postId => widget.post['id'] as String;

  @override
  void initState() {
    super.initState();
    _items = widget.session.store.checklist(_postId);
    for (final i in _items) {
      _marks[i['implement_id'] as String] = _Mark();
    }
  }

  bool _isCount(Map<String, dynamic> i) => i['tracking'] == 'count';

  bool get _complete => _items.every((i) {
        final m = _marks[i['implement_id']]!;
        return _isCount(i) ? m.counted != null : m.status != null;
      });

  Future<void> _save() async {
    setState(() => _busy = true);
    final s = widget.session;
    final id = newId();
    final items = [
      for (final i in _items)
        {
          'implement_id': i['implement_id'],
          'status': _marks[i['implement_id']]!.status ?? 'ok',
          if (_isCount(i)) 'counted': _marks[i['implement_id']]!.counted,
          if (_marks[i['implement_id']]!.note.trim().isNotEmpty) 'note': _marks[i['implement_id']]!.note.trim(),
        },
    ];
    await s.enqueue(GuardOp(
      id: id,
      kind: 'handover',
      label: '${_reception ? 'Recepción' : 'Entrega'} · ${widget.post['name']}',
      at: DateTime.now(),
      params: {
        'p_client_id': id,
        'p_post_id': _postId,
        'p_kind': widget.kind,
        'p_items': items,
        'p_note': null,
        'p_device_id': null,
        'p_shift_id': s.shift?['id'],
        'p_orders_seen': widget.ordersSeen,
        'p_lat': null,
        'p_lng': null,
        'p_happened_at': DateTime.now().toUtc().toIso8601String(),
      },
    ));
    await s.sync();
    if (!mounted) return;

    final res = s.store.results[id];
    String? sev;
    if (res is List && res.isNotEmpty) sev = (res.first as Map)['r_severity'] as String?;
    final sent = res != null;
    final what = _reception ? 'Puesto recibido' : 'Puesto entregado';
    if (!sent) {
      await showDone(context,
          title: '$what (guardado en el teléfono)',
          sub: 'No hay señal. Se enviará solo cuando vuelva.',
          color: gAmber,
          icon: Icons.cloud_off_rounded);
    } else if (sev == null) {
      await showDone(context, title: what, sub: 'Todo en orden.');
    } else {
      final word = sev == 'red' ? 'roja' : (sev == 'orange' ? 'naranja' : 'amarilla');
      await showDone(context,
          title: '$what con novedades',
          sub: 'Se avisó al supervisor (alerta $word).',
          color: sev == 'red' ? gRed : gOrange,
          icon: Icons.report_rounded);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Widget _statusButtons(String implId) {
    final m = _marks[implId]!;
    Widget btn(String value, String label, IconData icon, Color color) {
      final on = m.status == value;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Material(
            color: on ? color : Colors.white,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => setState(() => m.status = value),
              child: Container(
                height: 70,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: color, width: 2),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, color: on ? Colors.white : color, size: 28),
                    Text(label,
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w900, color: on ? Colors.white : color)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        btn('ok', 'Bien', Icons.check_rounded, gGreen),
        btn('damaged', 'Mal estado', Icons.build_rounded, gOrange),
        btn('missing', 'Falta', Icons.close_rounded, gRed),
      ],
    );
  }

  Widget _counter(String implId) {
    final m = _marks[implId]!;
    Widget round(IconData icon, VoidCallback? onTap) => SizedBox(
          width: 72,
          height: 72,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: gNavy,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: onTap,
            child: Icon(icon, size: 34),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Cuéntelas y escriba cuántas hay:', style: TextStyle(fontSize: 17, color: gSoft)),
        const SizedBox(height: 8),
        Row(
          children: [
            round(Icons.remove_rounded, (m.counted ?? 0) > 0 ? () => setState(() => m.counted = (m.counted ?? 0) - 1) : null),
            Expanded(
              child: Center(
                child: Text(m.counted == null ? '—' : '${m.counted}',
                    style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w900, color: gInk)),
              ),
            ),
            round(Icons.add_rounded, () => setState(() => m.counted = (m.counted ?? 0) + 1)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Checkbox(
              value: m.status == 'damaged',
              onChanged: (v) => setState(() => m.status = v == true ? 'damaged' : null),
            ),
            const Text('Alguna en mal estado', style: TextStyle(fontSize: 17)),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final last = widget.post['last'] as Map?;
    final from = _reception && last != null && last['kind'] == 'delivery' && last['actor_id'] != supabase.auth.currentUser?.id
        ? last
        : null;
    return GuardPage(
      title: _reception ? 'Recibir puesto' : 'Entregar puesto',
      bottom: GuardMainButton(
        label: _items.isEmpty
            ? (_reception ? 'Recibir el puesto' : 'Entregar el puesto')
            : (_complete ? 'Guardar' : 'Marque todo para guardar'),
        busy: _busy,
        color: _reception ? gGreen : gRed,
        onTap: _complete ? _save : null,
      ),
      children: [
        GuardTitle(
          widget.post['name'] as String? ?? 'Puesto',
          sub: _reception
              ? 'Revise cada cosa y marque cómo la encuentra. Si recibe sin reclamar, queda bajo su responsabilidad.'
              : 'Marque cómo deja cada cosa.',
        ),
        if (from != null)
          GuardCard(
            child: Text(
              'Le entrega: ${from['actor_name'] ?? 'el turno anterior'}'
              '${from['at'] != null ? ' · ${dayHhmm(DateTime.parse(from['at'] as String))}' : ''}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
        if (_items.isEmpty)
          const GuardCard(
            child: Text('Este puesto no tiene implementos registrados.', style: TextStyle(fontSize: 19)),
          ),
        for (final i in _items)
          GuardCard(
            border: _marks[i['implement_id']]!.status == 'missing'
                ? gRed
                : (_marks[i['implement_id']]!.status == 'damaged' ? gOrange : null),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(i['type_name'] as String? ?? 'Implemento',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                if ((i['label'] as String?)?.isNotEmpty == true || (i['serial'] as String?)?.isNotEmpty == true)
                  Text(
                    [
                      if ((i['label'] as String?)?.isNotEmpty == true) i['label'] as String,
                      if ((i['serial'] as String?)?.isNotEmpty == true) 'Serie ${i['serial']}',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 18, color: gSoft),
                  ),
                if (i['needs_weapon_license'] == true && _reception)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('Necesita licencia de portación vigente',
                        style: TextStyle(fontSize: 16, color: gRed, fontWeight: FontWeight.w700)),
                  ),
                const SizedBox(height: 12),
                if (_isCount(i)) _counter(i['implement_id'] as String) else _statusButtons(i['implement_id'] as String),
                if (_marks[i['implement_id']]!.status == 'damaged' || _marks[i['implement_id']]!.status == 'missing') ...[
                  const SizedBox(height: 10),
                  TextField(
                    style: const TextStyle(fontSize: 19),
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(hintText: '¿Qué pasó? (opcional)'),
                    onChanged: (v) => _marks[i['implement_id']]!.note = v,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
