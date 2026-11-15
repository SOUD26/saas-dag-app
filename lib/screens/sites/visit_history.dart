import 'dart:async';

import 'package:flutter/material.dart';

import '../../supabase.dart';
import '../../theme.dart';
import '../admin/admin_ui.dart' show Panel, Pill;
import '../admin/staff_file.dart' show fmtDpi;
import '../guard/readers.dart' show fmtPlate;
import 'visitor_photos.dart' show showVisitorPhoto;

/// Historial de visitas: un solo buscador por placa, DPI, nombre o empresa. Lo que cada quien ve lo
/// decide la base de datos: el admin su empresa, el supervisor sus sitios.
Future<void> openVisitHistory(
  BuildContext context, {
  String? companyId,
  String? siteId,
  String? query,
  bool canSeePhotos = false,
  List<(String, String)> sites = const [],
  String? title,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => VisitHistoryPage(
        companyId: companyId,
        siteId: siteId,
        query: query,
        canSeePhotos: canSeePhotos,
        sites: sites,
        title: title,
      ),
    ),
  );
}

class VisitHistoryPage extends StatefulWidget {
  const VisitHistoryPage({
    super.key,
    this.companyId,
    this.siteId,
    this.query,
    this.canSeePhotos = false,
    this.sites = const [],
    this.title,
  });

  final String? companyId;
  final String? siteId;
  final String? query;
  final bool canSeePhotos;
  final List<(String, String)> sites; // (id, nombre) para el filtro
  final String? title;

  @override
  State<VisitHistoryPage> createState() => _VisitHistoryPageState();
}

const _periods = ['Todo', 'Hoy', '7 días', '30 días', '90 días'];
const _limit = 200;

class _VisitHistoryPageState extends State<VisitHistoryPage> {
  late final TextEditingController _q = TextEditingController(text: widget.query ?? '');
  late String? _site = widget.siteId;
  int _period = 0;
  List<Map<String, dynamic>>? _rows;
  String? _error;
  bool _loading = false;
  Timer? _debounce;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  DateTime? _from() {
    final now = DateTime.now();
    switch (_period) {
      case 1:
        return DateTime(now.year, now.month, now.day);
      case 2:
        return now.subtract(const Duration(days: 7));
      case 3:
        return now.subtract(const Duration(days: 30));
      case 4:
        return now.subtract(const Duration(days: 90));
    }
    return null;
  }

  Future<void> _search() async {
    final req = ++_req;
    setState(() => _loading = true);
    try {
      final rows = await supabase.rpc('search_visits', params: {
        'p_q': _q.text.trim().isEmpty ? null : _q.text.trim(),
        'p_company': widget.companyId,
        'p_site': _site,
        'p_from': _from()?.toUtc().toIso8601String(),
        'p_to': null,
        'p_limit': _limit,
      });
      if (!mounted || req != _req) return;
      setState(() {
        _rows = [for (final r in (rows as List<dynamic>)) Map<String, dynamic>.from(r as Map)];
        _error = null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || req != _req) return;
      setState(() {
        _error = 'No se pudo buscar. Revisa tu conexión.';
        _loading = false;
      });
    }
  }

  void _typed(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), _search);
    setState(() {}); // para mostrar u ocultar la X
  }

  /// Tocar una placa, DPI, nombre o empresa busca todas sus visitas.
  void _searchFor(String text) {
    _debounce?.cancel();
    _q.text = text;
    _period = 0;
    _search();
  }

  // ───────────────────────── Formatos ─────────────────────────

  String _two(int n) => n.toString().padLeft(2, '0');

  String _date(DateTime d) => '${_two(d.day)}/${_two(d.month)}/${d.year}';

  String _when(String? iso) {
    if (iso == null) return '';
    final d = DateTime.parse(iso).toLocal();
    final now = DateTime.now();
    final today = d.year == now.year && d.month == now.month && d.day == now.day;
    return '${today ? 'hoy' : _date(d)} ${_two(d.hour)}:${_two(d.minute)}';
  }

  String _hm(String iso) {
    final d = DateTime.parse(iso).toLocal();
    return '${_two(d.hour)}:${_two(d.minute)}';
  }

  String _stay(String inIso, String outIso) {
    final m = DateTime.parse(outIso).difference(DateTime.parse(inIso)).inMinutes;
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final r = m % 60;
    return r == 0 ? '$h h' : '$h h $r min';
  }

  bool _sameDay(String a, String b) {
    final x = DateTime.parse(a).toLocal();
    final y = DateTime.parse(b).toLocal();
    return x.year == y.year && x.month == y.month && x.day == y.day;
  }

  String _doc(Map<String, dynamic> r) {
    final n = r['doc_number'] as String?;
    if (n == null || n.isEmpty) return '';
    final kind = r['doc_kind'] as String?;
    if (kind == 'dpi') return 'DPI ${fmtDpi(n)}';
    if (kind == 'license') return 'Licencia $n';
    if (kind == 'passport') return 'Pasaporte $n';
    return 'Doc. $n';
  }

  // ───────────────────────── Pantalla ─────────────────────────

  Widget _summary(List<Map<String, dynamic>> rows) {
    final f = rows.first;
    final visits = (f['total_visits'] as num?)?.toInt() ?? rows.length;
    final people = (f['total_people'] as num?)?.toInt() ?? 0;
    final vehicles = (f['total_vehicles'] as num?)?.toInt() ?? 0;
    final first = f['first_at'] as String?;
    final last = f['last_at'] as String?;
    String count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              count(visits, 'visita', 'visitas'),
              count(people, 'persona', 'personas'),
              if (vehicles > 0) count(vehicles, 'vehículo', 'vehículos'),
            ].join(' · '),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          if (first != null && last != null)
            Text(
              visits == 1 ? 'El ${_when(last)}' : 'Primera: ${_when(first)} · Última: ${_when(last)}',
              style: const TextStyle(color: AppColors.muted),
            ),
          if (visits > rows.length)
            Text('Se muestran las $_limit más recientes. Afina la búsqueda o el período para ver el resto.',
                style: const TextStyle(color: AppColors.muted, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _chip(String label, String query) => ActionChip(
        avatar: const Icon(Icons.search_rounded, size: 18),
        label: Text(label),
        visualDensity: VisualDensity.compact,
        onPressed: () => _searchFor(query),
      );

  Widget _visit(Map<String, dynamic> r) {
    final plate = r['plate'] as String?;
    final name = r['person_name'] as String?;
    final doc = r['doc_number'] as String?;
    final company = r['company_name'] as String?;
    final dest = r['destination'] as String?;
    final kind = r['kind'] as String?;
    final inside = r['status'] == 'inside';
    final entered = r['entered_at'] as String;
    final exited = r['exited_at'] as String?;
    final title = plate != null && plate.isNotEmpty ? fmtPlate(plate) : (name ?? 'Persona');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Panel(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  kind == 'pedestrian'
                      ? Icons.directions_walk_rounded
                      : (kind == 'motorcycle' ? Icons.two_wheeler_rounded : Icons.directions_car_rounded),
                  color: AppColors.navy,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                ),
                if (inside) const Pill('Dentro', AppColors.navy),
                if (widget.canSeePhotos && r['doc_photo_path'] != null)
                  IconButton(
                    tooltip: 'Ver foto del documento',
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      final deleted = await showVisitorPhoto(context, r);
                      if (deleted) await _search();
                    },
                    icon: const Icon(Icons.badge_rounded, color: AppColors.navy),
                  ),
              ],
            ),
            if (plate != null && plate.isNotEmpty && name != null && name.isNotEmpty) Text(name),
            if (_doc(r).isNotEmpty) Text(_doc(r), style: const TextStyle(color: AppColors.muted)),
            if ((company ?? '').isNotEmpty || (dest ?? '').isNotEmpty)
              Text(
                [
                  if ((company ?? '').isNotEmpty) company!,
                  if ((dest ?? '').isNotEmpty) '→ $dest',
                ].join(' '),
              ),
            const SizedBox(height: 2),
            Text(
              '${r['site_name'] ?? ''} · Entró ${_when(entered)}'
              '${exited != null ? ' · Salió ${_sameDay(entered, exited) ? _hm(exited) : _when(exited)} (${_stay(entered, exited)})' : ''}',
              style: const TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            Text(
              [
                if (r['entered_by_name'] != null) 'Registró ${r['entered_by_name']}',
                if (r['entry_offline'] == true) 'sin señal',
                if (exited != null && r['exited_by_name'] != null && r['exited_by_name'] != r['entered_by_name'])
                  'salida: ${r['exited_by_name']}',
              ].join(' · '),
              style: const TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: [
                if (plate != null && plate.isNotEmpty) _chip(fmtPlate(plate), plate),
                if (doc != null && doc.isNotEmpty) _chip(r['doc_kind'] == 'dpi' ? 'DPI' : 'Documento', doc),
                if (name != null && name.isNotEmpty && (doc == null || doc.isEmpty)) _chip(name, name),
                if ((company ?? '').isNotEmpty) _chip(company!, company),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final q = _q.text.trim();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: Text(widget.title ?? 'Historial de visitas'),
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final side = ((c.maxWidth - 760) / 2).clamp(16.0, double.infinity);
          return RefreshIndicator(
            onRefresh: _search,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(side, 16, side, 32),
              children: [
                TextField(
                  controller: _q,
                  autofocus: widget.query == null,
                  textInputAction: TextInputAction.search,
                  onChanged: _typed,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded),
                    hintText: 'Placa, DPI, nombre o empresa',
                    suffixIcon: q.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Borrar',
                            onPressed: () {
                              _q.clear();
                              _search();
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                if (widget.sites.length > 1)
                  DropdownButton<String?>(
                    isExpanded: true,
                    value: _site,
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('Todos los sitios')),
                      for (final s in widget.sites) DropdownMenuItem<String?>(value: s.$1, child: Text(s.$2)),
                    ],
                    onChanged: (v) {
                      setState(() => _site = v);
                      _search();
                    },
                  ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var i = 0; i < _periods.length; i++)
                      ChoiceChip(
                        label: Text(_periods[i]),
                        selected: _period == i,
                        onSelected: (_) {
                          setState(() => _period = i);
                          _search();
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_loading && rows == null)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator(color: AppColors.navy)),
                  )
                else if (_error != null)
                  Text(_error!, style: const TextStyle(color: AppColors.danger))
                else if (rows != null && rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      q.isEmpty ? 'Aún no hay visitas en este período.' : 'No se encontró nada con «$q».',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.muted),
                    ),
                  )
                else if (rows != null) ...[
                  if (_loading) const LinearProgressIndicator(color: AppColors.navy),
                  _summary(rows),
                  const SizedBox(height: 10),
                  for (final r in rows) _visit(r),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
