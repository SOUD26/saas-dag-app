import 'package:flutter/material.dart';

import '../../supabase.dart';
import '../../theme.dart';
import '../admin/admin_ui.dart' show Panel, toast;
import '../admin/staff_file.dart' show fmtDpi;
import '../guard/readers.dart' show fmtPlate;

/// Fotos del DPI o licencia de los visitantes. Solo el administrador de la empresa (y el súper
/// admin) las ve y las borra. Cada borrado queda en la bitácora.
Future<void> openVisitorPhotos(BuildContext context, {required String companyId, String? siteId, String? title}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => VisitorPhotosPage(companyId: companyId, siteId: siteId, title: title)),
  );
}

/// Abre una foto y permite borrarla. Devuelve true si se borró.
Future<bool> showVisitorPhoto(BuildContext context, Map<String, dynamic> entry) async {
  final path = entry['doc_photo_path'] as String?;
  if (path == null) return false;
  String? url;
  try {
    url = await supabase.storage.from('visitor_docs').createSignedUrl(path, 600);
  } catch (_) {
    url = null;
  }
  if (!context.mounted) return false;
  final delete = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(entryTitle(entry)),
      content: SizedBox(
        width: 520,
        child: url == null
            ? const Text('No se pudo abrir la foto.')
            : InteractiveViewer(child: Image.network(url, fit: BoxFit.contain)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Borrar foto', style: TextStyle(color: AppColors.danger)),
        ),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cerrar')),
      ],
    ),
  );
  if (delete != true || !context.mounted) return false;
  final n = await deleteVisitorPhotos([entry]);
  if (context.mounted) toast(context, n > 0 ? 'Foto borrada.' : 'No se pudo borrar la foto.');
  return n > 0;
}

String entryTitle(Map<String, dynamic> e) {
  final plate = e['plate'] as String?;
  final name = e['person_name'] as String?;
  return [if (plate != null && plate.isNotEmpty) fmtPlate(plate), if (name != null && name.isNotEmpty) name].join(' · ');
}

/// Borra las fotos del almacenamiento y luego su referencia en el ingreso.
Future<int> deleteVisitorPhotos(List<Map<String, dynamic>> entries) async {
  var done = 0;
  for (var i = 0; i < entries.length; i += 50) {
    final chunk = entries.sublist(i, i + 50 > entries.length ? entries.length : i + 50);
    final paths = [for (final e in chunk) e['doc_photo_path'] as String];
    try {
      await supabase.storage.from('visitor_docs').remove(paths);
      final n = await supabase.rpc('clear_entry_photos', params: {'p_ids': [for (final e in chunk) e['id']]});
      done += (n as num?)?.toInt() ?? 0;
    } catch (_) {
      break;
    }
  }
  return done;
}

class VisitorPhotosPage extends StatefulWidget {
  const VisitorPhotosPage({super.key, required this.companyId, this.siteId, this.title});
  final String companyId;
  final String? siteId;
  final String? title;

  @override
  State<VisitorPhotosPage> createState() => _VisitorPhotosPageState();
}

class _VisitorPhotosPageState extends State<VisitorPhotosPage> {
  List<Map<String, dynamic>>? _rows;
  String? _error;
  int _days = 30;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var q = supabase
          .from('access_entries')
          .select('id, site_id, plate, person_name, doc_kind, doc_number, entered_at, doc_photo_path, sites(name)')
          .eq('company_id', widget.companyId)
          .not('doc_photo_path', 'is', null);
      if (widget.siteId != null) q = q.eq('site_id', widget.siteId!);
      final rows = await q.order('entered_at', ascending: false).limit(500);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudieron cargar las fotos.');
    }
  }

  Future<void> _deleteOld() async {
    final rows = _rows ?? const [];
    final cut = DateTime.now().subtract(Duration(days: _days));
    final old = rows.where((r) => DateTime.parse(r['entered_at'] as String).isBefore(cut)).toList();
    if (old.isEmpty) {
      toast(context, 'No hay fotos de más de $_days días.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Borrar ${old.length} fotos?'),
        content: Text('Se borran para siempre las fotos de documento de más de $_days días. '
            'Los ingresos se quedan (placa, nombre, número y horas).'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Borrar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final n = await deleteVisitorPhotos(old);
    if (!mounted) return;
    setState(() => _busy = false);
    toast(context, '$n fotos borradas.');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: Text(widget.title ?? 'Fotos de documentos'),
      ),
      body: rows == null
          ? Center(child: _error == null ? const CircularProgressIndicator(color: AppColors.navy) : Text(_error!))
          : LayoutBuilder(
              builder: (context, c) {
                final side = ((c.maxWidth - 760) / 2).clamp(16.0, double.infinity);
                return RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(side, 16, side, 32),
                    children: [
                      const Text(
                        'Solo tú y los administradores de la empresa ven estas fotos. Guárdalas el menor tiempo posible: '
                        'si se filtran, son documentos de identidad de terceros.',
                        style: TextStyle(color: AppColors.muted),
                      ),
                      const SizedBox(height: 12),
                      Panel(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('${rows.length} fotos guardadas',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                const Text('Borrar las de más de '),
                                DropdownButton<int>(
                                  value: _days,
                                  items: [
                                    for (final d in const [7, 15, 30, 60, 90])
                                      DropdownMenuItem(value: d, child: Text('$d días')),
                                  ],
                                  onChanged: (v) => setState(() => _days = v ?? 30),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
                              onPressed: _busy ? null : _deleteOld,
                              icon: const Icon(Icons.delete_sweep_rounded),
                              label: Text(_busy ? 'Borrando…' : 'Borrar fotos viejas'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      for (final r in rows)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Panel(
                            onTap: () async {
                              final deleted = await showVisitorPhoto(context, r);
                              if (deleted) await _load();
                            },
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            child: Row(
                              children: [
                                const Icon(Icons.badge_rounded, color: AppColors.navy),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(entryTitle(r), style: const TextStyle(fontWeight: FontWeight.w700)),
                                      Text(
                                        [
                                          (r['sites'] as Map?)?['name'] as String? ?? '',
                                          if (r['doc_number'] != null)
                                            r['doc_kind'] == 'dpi' ? fmtDpi(r['doc_number'] as String) : r['doc_number'] as String,
                                          _when(r['entered_at'] as String),
                                        ].where((x) => x.isNotEmpty).join(' · '),
                                        style: const TextStyle(color: AppColors.muted, fontSize: 13),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  String _when(String iso) {
    final d = DateTime.parse(iso).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }
}
