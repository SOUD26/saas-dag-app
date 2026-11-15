import 'package:flutter/material.dart';

import '../../supabase.dart';
import 'guard_session.dart';
import 'guard_store.dart';
import 'guard_ui.dart';
import 'readers.dart' show newId;

const _cats = <String, (String, String, IconData, Color)>{
  'sin_novedad': ('Sin novedad', 'Un toque y queda anotado con la hora', Icons.check_circle_rounded, gGreen),
  'novedad': ('Novedad', 'Algo que el supervisor debe saber', Icons.edit_note_rounded, gBlue),
  'incidente': ('Incidente', 'Avisa de inmediato al supervisor', Icons.report_rounded, gRed),
  'mantenimiento': ('Mantenimiento', 'Luz, portón, agua, cámaras…', Icons.build_rounded, gAmber),
};

/// Bitácora de novedades del sitio.
class GuardLogPage extends StatefulWidget {
  const GuardLogPage({super.key, required this.session});
  final GuardSession session;

  @override
  State<GuardLogPage> createState() => _GuardLogPageState();
}

class _GuardLogPageState extends State<GuardLogPage> {
  String? _cat;
  final _text = TextEditingController();
  bool _busy = false;
  List<Map<String, dynamic>> _recent = [];

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final id = widget.session.siteId;
    if (id == null) return;
    try {
      final rows = await supabase
          .from('site_log')
          .select('id, category, body, happened_at')
          .eq('site_id', id)
          .order('happened_at', ascending: false)
          .limit(15);
      if (mounted) setState(() => _recent = rows);
    } catch (_) {
      // Sin señal: se muestran solo las que esperan envío.
    }
  }

  Future<void> _save(String cat) async {
    setState(() => _busy = true);
    final s = widget.session;
    final id = newId();
    final now = DateTime.now();
    await s.enqueue(GuardOp(
      id: id,
      kind: 'log',
      label: _cats[cat]!.$1,
      at: now,
      params: {
        'p_id': id,
        'p_site_id': s.siteId,
        'p_post_id': s.dutyPost?['id'],
        'p_category': cat,
        'p_body': _text.text.trim().isEmpty ? null : _text.text.trim(),
        'p_happened_at': now.toUtc().toIso8601String(),
        'p_device_id': null,
      },
    ));
    await s.sync();
    if (!mounted) return;
    await showDone(
      context,
      title: '${_cats[cat]!.$1} anotada',
      sub: '${hhmm(now)}${cat == 'incidente' ? ' · Se avisó al supervisor.' : ''}${s.pending > 0 ? '\nSin señal: se enviará solo.' : ''}',
      color: cat == 'incidente' ? gRed : gGreen,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _cat = null;
      _text.clear();
    });
    _loadRecent();
  }

  @override
  Widget build(BuildContext context) {
    final cat = _cat;
    if (cat != null) {
      final c = _cats[cat]!;
      return GuardPage(
        title: c.$1,
        bottom: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GuardMainButton(
              label: 'Guardar',
              color: c.$4,
              busy: _busy,
              onTap: _text.text.trim().isEmpty ? null : () => _save(cat),
            ),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _cat = null),
              child: const Text('Atrás', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
        children: [
          GuardTitle('¿Qué pasó?', sub: 'Hoy ${hhmm(DateTime.now())}. Puede usar el micrófono del teclado para dictar.'),
          TextField(
            controller: _text,
            autofocus: true,
            minLines: 4,
            maxLines: 10,
            maxLength: 2000,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 21),
            decoration: const InputDecoration(hintText: 'Escriba aquí'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      );
    }

    final pending = widget.session.store.outbox.where((o) => o.kind == 'log').toList();
    return GuardPage(
      title: 'Bitácora',
      children: [
        GuardTitle('Anotar en la bitácora', sub: 'Hoy ${hhmm(DateTime.now())}'),
        for (final e in _cats.entries)
          GuardButton(
            icon: e.value.$3,
            label: e.value.$1,
            sub: e.value.$2,
            color: e.value.$4,
            onTap: _busy
                ? null
                : () {
                    if (e.key == 'sin_novedad') {
                      _save('sin_novedad');
                    } else {
                      setState(() => _cat = e.key);
                    }
                  },
          ),
        if (pending.isNotEmpty || _recent.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Últimas anotaciones', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
        ],
        for (final o in pending)
          GuardCard(
            child: Text('${hhmm(o.at)} · ${o.label} · sin enviar${o.params['p_body'] != null ? '\n${o.params['p_body']}' : ''}',
                style: const TextStyle(fontSize: 18)),
          ),
        for (final r in _recent)
          GuardCard(
            border: r['category'] == 'incidente' ? gRed : null,
            child: Text(
              '${dayHhmm(DateTime.parse(r['happened_at'] as String))} · ${_cats[r['category']]?.$1 ?? r['category']}'
              '${(r['body'] as String?)?.isNotEmpty == true ? '\n${r['body']}' : ''}',
              style: const TextStyle(fontSize: 18),
            ),
          ),
      ],
    );
  }
}
