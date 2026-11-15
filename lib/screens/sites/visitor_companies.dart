import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../supabase.dart';
import '../../theme.dart';
import '../admin/admin_ui.dart' show Panel, Pill, toast;

/// Lista de empresas que visitan (la que elige el guarda al registrar un ingreso).
Future<void> openVisitorCompanies(BuildContext context, {required String companyId}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => VisitorCompaniesPage(companyId: companyId)),
  );
}

class VisitorCompaniesPage extends StatefulWidget {
  const VisitorCompaniesPage({super.key, required this.companyId});
  final String companyId;

  @override
  State<VisitorCompaniesPage> createState() => _VisitorCompaniesPageState();
}

class _VisitorCompaniesPageState extends State<VisitorCompaniesPage> {
  List<Map<String, dynamic>>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await supabase
          .from('visitor_companies')
          .select('id, name, active, sort_order')
          .eq('company_id', widget.companyId)
          .order('sort_order')
          .order('name');
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo cargar la lista.');
    }
  }

  Future<void> _edit([Map<String, dynamic>? row]) async {
    final ctl = TextEditingController(text: row?['name'] as String? ?? '');
    var active = (row?['active'] as bool?) ?? true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(row == null ? 'Nueva empresa' : 'Editar empresa'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctl,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Jardinería López'),
              ),
              if (row != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: active,
                  onChanged: (v) => set(() => active = v),
                  title: const Text('Aparece en la lista del guarda'),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    final name = ctl.text.trim();
    ctl.dispose();
    if (ok != true || name.isEmpty) return;
    try {
      if (row == null) {
        await supabase.from('visitor_companies').insert({'company_id': widget.companyId, 'name': name});
      } else {
        await supabase.from('visitor_companies').update({'name': name, 'active': active}).eq('id', row['id'] as String);
      }
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) toast(context, e.code == '23505' ? 'Ya existe una empresa con ese nombre.' : 'No se pudo guardar.');
    } catch (_) {
      if (mounted) toast(context, 'No se pudo guardar.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: const Text('Empresas que visitan'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nueva'),
      ),
      body: rows == null
          ? Center(child: _error == null ? const CircularProgressIndicator(color: AppColors.navy) : Text(_error!))
          : LayoutBuilder(
              builder: (context, c) {
                final side = ((c.maxWidth - 760) / 2).clamp(16.0, double.infinity);
                return ListView(
                  padding: EdgeInsets.fromLTRB(side, 16, side, 96),
                  children: [
                    const Text(
                      'El guarda elige de esta lista al registrar un ingreso ("¿De dónde viene?"). '
                      'Si no está, puede escribirla como "Otra".',
                      style: TextStyle(color: AppColors.muted),
                    ),
                    const SizedBox(height: 14),
                    for (final r in rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Panel(
                          onTap: () => _edit(r),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(r['name'] as String? ?? '',
                                    style: const TextStyle(fontWeight: FontWeight.w700)),
                              ),
                              if (r['active'] != true) const Pill('Oculta', AppColors.muted),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}
