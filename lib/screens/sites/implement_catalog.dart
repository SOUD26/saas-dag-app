import 'package:flutter/material.dart';

import '../../theme.dart';
import '../admin/admin_ui.dart' show Panel, Pill, toast;
import 'site_data.dart';

/// Catálogo de implementos de la empresa y su nivel de alerta.
Future<void> openImplementCatalog(BuildContext context, {required String companyId}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => ImplementCatalogPage(companyId: companyId)),
  );
}

class ImplementCatalogPage extends StatefulWidget {
  const ImplementCatalogPage({super.key, required this.companyId});
  final String companyId;

  @override
  State<ImplementCatalogPage> createState() => _ImplementCatalogPageState();
}

class _ImplementCatalogPageState extends State<ImplementCatalogPage> {
  List<ImplType>? _types;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await loadImplTypes(companyId: widget.companyId);
      if (!mounted) return;
      setState(() {
        _types = t;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'No se pudo cargar el catálogo.');
    }
  }

  Future<void> _edit([ImplType? t]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ImplDialog(companyId: widget.companyId, type: t),
    );
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final types = _types;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: const Text('Implementos'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nuevo'),
      ),
      body: types == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator(color: AppColors.navy)
                  : Text(_error!),
            )
          : LayoutBuilder(
              builder: (context, c) {
                final side = ((c.maxWidth - 760) / 2).clamp(16.0, double.infinity);
                return ListView(
                  padding: EdgeInsets.fromLTRB(side, 16, side, 96),
                  children: [
                    const Text(
                      'El color es la alerta que sale si el implemento falta en un relevo. '
                      'Si está en mal estado, baja un nivel. Roja: actuar ya · Naranja: revisar hoy · Amarilla: revisar cuando se pueda.',
                      style: TextStyle(color: AppColors.muted),
                    ),
                    const SizedBox(height: 14),
                    for (final t in types)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Panel(
                          onTap: () => _edit(t),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          child: Row(
                            children: [
                              Icon(Icons.circle, size: 14, color: t.active ? sevColor(t.severity) : AppColors.line),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(t.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                                    Text(
                                      '${implTracking[t.tracking] ?? ''}${t.weapon ? ' · exige licencia de portación' : ''}',
                                      style: const TextStyle(color: AppColors.muted, fontSize: 13),
                                    ),
                                  ],
                                ),
                              ),
                              t.active ? Pill(sevLabel(t.severity), sevColor(t.severity)) : const Pill('Inactivo', AppColors.muted),
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

class _ImplDialog extends StatefulWidget {
  const _ImplDialog({required this.companyId, this.type});
  final String companyId;
  final ImplType? type;

  @override
  State<_ImplDialog> createState() => _ImplDialogState();
}

class _ImplDialogState extends State<_ImplDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.type?.name ?? '');
  late String _category = widget.type?.category ?? 'equipo';
  late String _severity = widget.type?.severity ?? 'yellow';
  late String _tracking = widget.type?.tracking ?? 'unit';
  late bool _weapon = widget.type?.weapon ?? false;
  late bool _active = widget.type?.active ?? true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Escribe el nombre.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await saveImplType(
        id: widget.type?.id,
        companyId: widget.companyId,
        name: _name.text.trim(),
        category: _category,
        severity: _severity,
        tracking: _tracking,
        weapon: _weapon,
        active: _active,
      );
      if (!mounted) return;
      toast(context, 'Implemento guardado.');
      Navigator.of(context).pop(true);
    } on SiteError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'No se pudo guardar. Revisa tu conexión.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.type == null ? 'Nuevo implemento' : 'Editar implemento'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: 'Nombre', errorText: _error),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                // ignore: deprecated_member_use
                value: _category,
                decoration: const InputDecoration(labelText: 'Tipo'),
                items: [
                  for (final e in implCategories.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _category = v ?? 'otro'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                // ignore: deprecated_member_use
                value: _tracking,
                decoration: const InputDecoration(labelText: 'Cómo se revisa en el relevo'),
                items: [
                  for (final e in implTracking.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _tracking = v ?? 'unit'),
              ),
              const SizedBox(height: 14),
              const Text('Alerta si falta', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final s in const ['red', 'orange', 'yellow'])
                    ChoiceChip(
                      label: Text(sevLabel(s)),
                      selected: _severity == s,
                      selectedColor: sevColor(s).withValues(alpha: 0.2),
                      avatar: Icon(Icons.circle, size: 12, color: sevColor(s)),
                      onSelected: (_) => setState(() => _severity = s),
                    ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _weapon,
                onChanged: (v) => setState(() => _weapon = v),
                title: const Text('Exige licencia de portación'),
                subtitle: const Text('Si quien lo recibe no la tiene vigente: alerta roja.'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('Activo'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Guardar')),
      ],
    );
  }
}
