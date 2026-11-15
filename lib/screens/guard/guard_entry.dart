import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../admin/staff_file.dart' show dpiLooksValid, fmtDpi, onlyDigits;
import 'files.dart';
import 'guard_session.dart';
import 'guard_store.dart';
import 'guard_ui.dart';
import 'ocr.dart';
import 'readers.dart';

/// Ingreso en pocos toques: qué entra → placa (foto) → documento (foto) → de dónde viene → guardar.
/// La fecha y la hora se ponen solas. Queda "dentro" hasta que se marque la salida.
class GuardEntryPage extends StatefulWidget {
  const GuardEntryPage({super.key, required this.session});
  final GuardSession session;

  @override
  State<GuardEntryPage> createState() => _GuardEntryPageState();
}

class _GuardEntryPageState extends State<GuardEntryPage> {
  int _step = 0; // 0 qué entra · 1 placa · 2 documento · 3 de dónde viene · 4 revisar
  String _kind = 'vehicle';
  String _docKind = 'dpi';
  final _plate = TextEditingController();
  final _name = TextEditingController();
  final _doc = TextEditingController();
  final _dest = TextEditingController();
  final _other = TextEditingController();
  final _search = TextEditingController();
  String? _photo; // foto del documento, hasta guardar
  String? _companyId;
  String? _companyName;
  bool _otherCompany = false;
  bool _reading = false;
  bool _busy = false;
  bool _saved = false;
  final _picker = ImagePicker();

  @override
  void dispose() {
    // Si no se guardó, la foto del documento no se queda en el teléfono.
    final p = _photo;
    if (!_saved && p != null) deletePhoto(p);
    for (final c in [_plate, _name, _doc, _dest, _other, _search]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _vehicle => _kind != 'pedestrian';
  String get _plateClean => _plate.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  String get _docClean =>
      _docKind == 'dpi' || _docKind == 'license' ? onlyDigits(_doc.text) : _doc.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  int get _totalSteps => _vehicle ? 4 : 3;
  int get _stepNumber => _vehicle ? _step : (_step <= 1 ? 1 : _step - 1);

  void _go(int step) => setState(() => _step = step);

  Future<String?> _takePhoto({int quality = 85}) async {
    try {
      final x = await _picker.pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: quality);
      return x?.path;
    } catch (_) {
      if (mounted) {
        await showDone(context,
            title: 'No se pudo abrir la cámara', sub: 'Escriba los datos con el teclado.', color: gOrange, icon: Icons.no_photography_rounded);
      }
      return null;
    }
  }

  Future<void> _photoPlate() async {
    final path = await _takePhoto();
    if (path == null || !mounted) return;
    setState(() => _reading = true);
    final text = await readTextFromImage(path);
    await discardImage(path); // la foto de la placa no se guarda
    final plate = text == null ? null : findPlate(text, moto: _kind == 'motorcycle');
    if (!mounted) return;
    setState(() {
      _reading = false;
      if (plate != null) _plate.text = fmtPlate(plate);
    });
    if (plate == null) {
      await showDone(context,
          title: 'No se leyó la placa', sub: 'Escríbala con el teclado.', color: gOrange, icon: Icons.edit_rounded);
    }
  }

  Future<void> _photoDoc(String kind) async {
    final path = await _takePhoto(quality: 80);
    if (path == null || !mounted) return;
    setState(() {
      _reading = true;
      _docKind = kind;
    });
    final old = _photo;
    if (old != null) await deletePhoto(old);
    _photo = path;
    final text = await readTextFromImage(path);
    final r = text == null ? null : readId(text);
    if (!mounted) return;
    setState(() {
      _reading = false;
      if (r != null) {
        if (r.license) _docKind = 'license';
        if (r.cui != null) _doc.text = fmtDpi(r.cui);
        if (r.name != null && _name.text.trim().isEmpty) _name.text = r.name!;
      }
    });
    if (r?.cui == null) {
      await showDone(context,
          title: 'No se leyó el número',
          sub: 'La foto quedó guardada. Escriba el número y el nombre.',
          color: gOrange,
          icon: Icons.edit_rounded);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final s = widget.session;
    final site = s.site;
    if (site == null) {
      setState(() => _busy = false);
      return;
    }
    final siteId = site['site_id'] as String;
    final id = newId();
    final now = DateTime.now();
    final doc = _docClean;
    final plate = _vehicle ? _plateClean : null;
    final company = _otherCompany ? _other.text.trim() : _companyName;
    final data = {
      'kind': _kind,
      'plate': plate,
      'person_name': _name.text.trim(),
      'doc_kind': doc.isEmpty ? null : _docKind,
      'doc_number': doc,
      'visitor_company_id': _otherCompany ? null : _companyId,
      'visitor_company_text': _otherCompany ? _other.text.trim() : null,
      'destination': _dest.text.trim(),
    };
    await s.store.addInside(
      siteId,
      InsideEntry(
        id: id,
        kind: _kind,
        enteredAt: now,
        plate: plate,
        personName: _name.text.trim().isEmpty ? null : _name.text.trim(),
        docKind: doc.isEmpty ? null : _docKind,
        docLast4: doc.length >= 4 ? doc.substring(doc.length - 4) : null,
        companyName: company,
        destination: _dest.text.trim().isEmpty ? null : _dest.text.trim(),
        synced: false,
      ),
    );
    await s.enqueue(GuardOp(
      id: id,
      kind: 'entry',
      label: 'Ingreso ${plate != null ? fmtPlate(plate) : _name.text.trim()}',
      at: now,
      params: {
        'p_id': id,
        'p_site_id': siteId,
        'p_post_id': s.dutyPost?['id'],
        'p_data': data,
        'p_happened_at': now.toUtc().toIso8601String(),
        'p_device_id': null,
      },
    ));
    final photo = _photo;
    final companyId = (s.ctx?['company'] as Map?)?['id'] as String?;
    if (photo != null && companyId != null) {
      final kept = await keepPhoto(photo, id);
      _photo = null;
      if (kept != null) {
        await s.enqueue(GuardOp(
          id: newId(),
          kind: 'photo',
          label: 'Foto del documento',
          at: now,
          params: {'entry_id': id, 'local_path': kept, 'path': '$companyId/$siteId/$id.jpg'},
        ));
      }
    }
    _saved = true;
    await s.sync();
    if (!mounted) return;
    await showDone(
      context,
      title: 'Ingreso guardado',
      sub: '${hhmm(now)} · ${plate != null ? fmtPlate(plate) : _name.text.trim()}. Queda "dentro" hasta que marque la salida.'
          '${s.pending > 0 ? '\nSin señal: se enviará solo.' : ''}',
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  // ───────────────────────── Pasos ─────────────────────────

  Widget _stepHeader(String title, {String? sub}) {
    return GuardTitle(
      title,
      sub: '${_step == 0 ? '' : 'Paso $_stepNumber de $_totalSteps · '}Hoy ${hhmm(DateTime.now())}${sub == null ? '' : '\n$sub'}',
    );
  }

  List<Widget> _kindStep() => [
        _stepHeader('¿Qué entra?'),
        GuardButton(
          icon: Icons.directions_car_rounded,
          label: 'Carro o camión',
          color: gBlue,
          onTap: () => setState(() {
            _kind = 'vehicle';
            _step = 1;
          }),
        ),
        GuardButton(
          icon: Icons.two_wheeler_rounded,
          label: 'Moto',
          color: gBlue,
          onTap: () => setState(() {
            _kind = 'motorcycle';
            _step = 1;
          }),
        ),
        GuardButton(
          icon: Icons.directions_walk_rounded,
          label: 'A pie',
          color: gBlue,
          onTap: () => setState(() {
            _kind = 'pedestrian';
            _step = 2;
          }),
        ),
      ];

  List<Widget> _plateStep() => [
        _stepHeader('Placa', sub: ocrAvailable ? 'Tome la foto de frente y de cerca.' : null),
        if (ocrAvailable)
          GuardButton(
            icon: Icons.photo_camera_rounded,
            label: _reading ? 'Leyendo…' : 'Tomar foto de la placa',
            color: gNavy,
            onTap: _reading ? null : _photoPlate,
          ),
        TextField(
          controller: _plate,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, letterSpacing: 2),
          textAlign: TextAlign.center,
          decoration: const InputDecoration(hintText: 'P-123ABC'),
          onChanged: (_) => setState(() {}),
        ),
      ];

  List<Widget> _docStep() {
    final digits = _docKind == 'dpi' || _docKind == 'license';
    final clean = _docClean;
    final suspicious = digits && clean.length == 13 && !dpiLooksValid(clean);
    return [
      _stepHeader(_vehicle ? 'Documento del conductor' : 'Documento de la persona',
          sub: ocrAvailable ? 'Tome la foto del DPI o de la licencia, de frente.' : null),
      if (ocrAvailable) ...[
        GuardButton(
          icon: Icons.badge_rounded,
          label: _reading ? 'Leyendo…' : 'Foto del DPI',
          color: gNavy,
          onTap: _reading ? null : () => _photoDoc('dpi'),
        ),
        GuardButton(
          icon: Icons.credit_card_rounded,
          label: 'Foto de la licencia',
          color: gNavy,
          onTap: _reading ? null : () => _photoDoc('license'),
        ),
      ],
      if (_photo != null)
        const GuardCard(
          color: Color(0xFFE8F5E9),
          border: gGreen,
          child: Text('Foto del documento lista ✓', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: gGreen)),
        ),
      TextField(
        controller: _name,
        textCapitalization: TextCapitalization.words,
        style: const TextStyle(fontSize: 22),
        decoration: const InputDecoration(labelText: 'Nombre'),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _doc,
        keyboardType: digits ? TextInputType.number : TextInputType.text,
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 1),
        decoration: InputDecoration(labelText: _docKind == 'license' ? 'Número de licencia' : 'Número de DPI'),
        onChanged: (_) => setState(() {}),
      ),
      if (suspicious)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Revise el número: no parece un DPI válido.',
              style: TextStyle(fontSize: 17, color: gOrange, fontWeight: FontWeight.w700)),
        ),
    ];
  }

  List<Widget> _companyStep() {
    final q = _search.text.trim().toLowerCase();
    final list = widget.session.store.visitorCompanies
        .where((c) => q.isEmpty || (c['name'] as String? ?? '').toLowerCase().contains(q))
        .toList();
    Widget option(String label, bool selected, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: selected ? gBlue : Colors.white,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onTap,
              child: Container(
                constraints: const BoxConstraints(minHeight: 62),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: selected ? gBlue : const Color(0xFFD0D5DD), width: 2),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(label,
                          style: TextStyle(
                              fontSize: 21, fontWeight: FontWeight.w800, color: selected ? Colors.white : gInk)),
                    ),
                    if (selected) const Icon(Icons.check_circle_rounded, color: Colors.white, size: 30),
                  ],
                ),
              ),
            ),
          ),
        );
    return [
      _stepHeader('¿De dónde viene?'),
      if (widget.session.store.visitorCompanies.length > 6) ...[
        TextField(
          controller: _search,
          style: const TextStyle(fontSize: 20),
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Buscar'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
      ],
      for (final c in list)
        option(c['name'] as String? ?? '', !_otherCompany && _companyId == c['id'], () => setState(() {
              _otherCompany = false;
              _companyId = c['id'] as String?;
              _companyName = c['name'] as String?;
            })),
      option('Otra (escribir)', _otherCompany, () => setState(() => _otherCompany = true)),
      if (_otherCompany)
        TextField(
          controller: _other,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          style: const TextStyle(fontSize: 21),
          decoration: const InputDecoration(labelText: 'Nombre de la empresa'),
          onChanged: (_) => setState(() {}),
        ),
      const SizedBox(height: 12),
      TextField(
        controller: _dest,
        textCapitalization: TextCapitalization.sentences,
        style: const TextStyle(fontSize: 21),
        decoration: const InputDecoration(labelText: '¿A dónde va? (opcional)', hintText: 'Casa 12, Oficina 3…'),
      ),
    ];
  }

  List<Widget> _reviewStep() {
    final doc = _docClean;
    Widget line(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 120, child: Text(k, style: const TextStyle(fontSize: 18, color: gSoft))),
              Expanded(child: Text(v, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800))),
            ],
          ),
        );
    return [
      _stepHeader('Revise y guarde'),
      GuardCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            line('Entra', _kind == 'vehicle' ? 'Carro o camión' : (_kind == 'motorcycle' ? 'Moto' : 'A pie')),
            if (_vehicle) line('Placa', fmtPlate(_plateClean)),
            if (_name.text.trim().isNotEmpty) line('Nombre', _name.text.trim()),
            if (doc.isNotEmpty) line(_docKind == 'license' ? 'Licencia' : 'DPI', _docKind == 'dpi' ? fmtDpi(doc) : doc),
            line('Foto', _photo != null ? 'Sí' : 'No'),
            line('Viene de', _otherCompany ? _other.text.trim() : (_companyName ?? '—')),
            if (_dest.text.trim().isNotEmpty) line('Va a', _dest.text.trim()),
            line('Hora', 'Hoy ${hhmm(DateTime.now())} (automática)'),
          ],
        ),
      ),
    ];
  }

  bool get _canNext {
    switch (_step) {
      case 1:
        return _plateClean.length >= 4;
      case 2:
        return _vehicle || _name.text.trim().isNotEmpty || _docClean.isNotEmpty;
      case 3:
        return _otherCompany ? _other.text.trim().isNotEmpty : _companyId != null;
    }
    return true;
  }

  Widget? _bottom() {
    if (_step == 0) return null;
    final last = _step == 4;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GuardMainButton(
          label: last ? 'Guardar ingreso' : (_step == 2 && _docClean.isEmpty && _vehicle ? 'Seguir sin documento' : 'Siguiente'),
          color: last ? gGreen : gNavy,
          busy: _busy,
          onTap: _canNext ? (last ? _save : () => _go(_step + 1)) : null,
        ),
        TextButton(
          onPressed: _busy ? null : () => _go(_step == 2 && !_vehicle ? 0 : _step - 1),
          child: const Text('Atrás', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> body;
    switch (_step) {
      case 0:
        body = _kindStep();
        break;
      case 1:
        body = _plateStep();
        break;
      case 2:
        body = _docStep();
        break;
      case 3:
        body = _companyStep();
        break;
      default:
        body = _reviewStep();
    }
    return GuardPage(title: 'Ingreso', bottom: _bottom(), children: body);
  }
}
