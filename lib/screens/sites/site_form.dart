import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../theme.dart';
import '../admin/admin_data.dart' show AGuard;
import '../admin/admin_ui.dart' show FormCard, Pill, toast;
import '../admin/staff_file.dart' show fmtDate, parseDmy, todayDate;
import 'site_data.dart';

/// Abre el formulario del sitio. Devuelve true si se guardó.
/// [asAdmin]: el sitio nace aprobado y se asignan guardas por puesto.
/// Sin [asAdmin] (supervisor): se guarda como borrador o se envía a aprobación.
Future<bool?> openSiteForm(
  BuildContext context, {
  required bool asAdmin,
  String? siteId,
  String? companyId,
  List<AGuard> guards = const [],
}) {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => SiteFormPage(
        asAdmin: asAdmin,
        siteId: siteId,
        companyId: companyId,
        guards: guards,
      ),
    ),
  );
}

class SiteFormPage extends StatefulWidget {
  const SiteFormPage({
    super.key,
    required this.asAdmin,
    this.siteId,
    this.companyId,
    this.guards = const [],
  });

  final bool asAdmin;
  final String? siteId;
  final String? companyId;
  final List<AGuard> guards;

  @override
  State<SiteFormPage> createState() => _SiteFormPageState();
}

const _kNone = '__none__';
const _kNew = '__new__';
const _kCustom = -1;
final _timeRe = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
const _roundOptions = [30, 60, 90, 120, 180, 240, 360];
const _guatemala = LatLng(14.6349, -90.5069);

String _everyLabel(int m) {
  if (m < 60) return 'Cada $m minutos';
  final h = m ~/ 60;
  final r = m % 60;
  final hs = h == 1 ? '1 hora' : '$h horas';
  return r == 0 ? 'Cada $hs' : 'Cada $hs y $r min';
}

class _SiteFormPageState extends State<SiteFormPage> {
  bool _loading = true;
  bool _busy = false;
  bool _locating = false;
  String? _error;
  String? _loadError;
  late SiteFull _s;
  List<ImplType> _types = [];
  List<(String, String)> _clients = [];
  bool _newClient = false;
  final _map = MapController();
  final _ctls = <String, TextEditingController>{};

  bool get _isNew => widget.siteId == null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctls.values) {
      c.dispose();
    }
    _map.dispose();
    super.dispose();
  }

  /// Un controlador de texto por campo de cada objeto (puesto, implemento, contacto…).
  TextEditingController _ctl(Object owner, String field, String initial) =>
      _ctls.putIfAbsent('${identityHashCode(owner)}:$field', () => TextEditingController(text: initial));

  Future<void> _load() async {
    try {
      final types = await loadImplTypes(companyId: widget.companyId);
      final clients = await loadClientOptions(widget.companyId);
      final s = _isNew
          ? SiteFull(
              companyId: widget.companyId,
              status: widget.asAdmin ? 'approved' : 'draft',
              posts: [
                EditPost(
                  name: 'Garita principal',
                  coverFrom: '07:00',
                  coverTo: '07:00',
                  shiftHours: 24,
                  guardsRequired: 3,
                ),
              ],
            )
          : await loadSiteFull(widget.siteId!);
      if (!mounted) return;
      setState(() {
        _types = types;
        _clients = clients;
        _s = s;
        _newClient = s.clientId == null && s.proposedClientName.isNotEmpty;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = 'No se pudo cargar el sitio. Revisa tu conexión.';
        _loading = false;
      });
    }
  }

  ImplType? _type(String id) {
    for (final t in _types) {
      if (t.id == id) return t;
    }
    return null;
  }

  List<AGuard> get _activeGuards => widget.guards.where((g) => g.active).toList();

  // ───────────────────────── Guardar ─────────────────────────

  String? _validate() {
    if (_ctl(_s, 'name', _s.name).text.trim().isEmpty) return 'Escribe el nombre del sitio.';
    if (_s.lat == null || _s.lng == null) return 'Marca la ubicación del sitio en el mapa.';
    if (_newClient && _ctl(_s, 'client', _s.proposedClientName).text.trim().isEmpty) {
      return 'Escribe el nombre del cliente nuevo.';
    }
    if (_s.posts.isEmpty) return 'El sitio necesita al menos un puesto.';
    for (final p in _s.posts) {
      if (p.name.trim().isEmpty) return 'Cada puesto necesita un nombre.';
      if (!_timeRe.hasMatch(p.coverFrom) || !_timeRe.hasMatch(p.coverTo)) {
        return 'Revisa el horario de "${p.name}": usa el formato 07:00.';
      }
      if (p.shiftHours < 1 || p.shiftHours > 24) return 'El turno de "${p.name}" debe durar de 1 a 24 horas.';
      if (p.days.isEmpty) return 'Elige los días del puesto "${p.name}".';
      for (final i in p.implements) {
        if (i.quantity < 1) return 'Revisa las cantidades del puesto "${p.name}".';
      }
    }
    for (final c in _s.contacts) {
      if (c.name.trim().isEmpty) return 'Cada administrador o contacto necesita su nombre.';
      final txt = _ctl(c, 'trained', c.trainedAt == null ? '' : fmtDate(c.trainedAt!)).text.trim();
      if (txt.isNotEmpty && c.trainedAt == null) return 'La fecha de capacitación de ${c.name} no es válida (dd/mm/aaaa).';
      if (c.trainedAt != null && c.trainedAt!.isAfter(todayDate())) {
        return 'La fecha de capacitación no puede ser futura.';
      }
    }
    if (_s.roundsRequired && _s.roundsEvery < 15) return 'Indica cada cuánto se hacen las rondas.';
    return null;
  }

  Future<void> _save({bool submit = false}) async {
    FocusScope.of(context).unfocus();
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    _s.name = _ctl(_s, 'name', _s.name).text;
    _s.address = _ctl(_s, 'address', _s.address).text;
    if (_newClient) {
      _s.clientId = null;
      _s.proposedClientName = _ctl(_s, 'client', _s.proposedClientName).text;
    } else {
      _s.proposedClientName = '';
    }
    if (widget.asAdmin) {
      final ok = {for (final g in _activeGuards) g.id};
      for (final p in _s.posts) {
        p.guards.removeWhere((g) => !ok.contains(g));
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await saveSite(_s.id, _s.toPayload(assignGuards: widget.asAdmin), submit: submit);
      if (!mounted) return;
      toast(
        context,
        widget.asAdmin
            ? 'Sitio guardado.'
            : (submit ? 'Enviado al administrador para su aprobación.' : 'Borrador guardado.'),
      );
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
        _error = 'No se pudo guardar. Revisa tu conexión e intenta de nuevo.';
      });
    }
  }

  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const SiteError('Activa la ubicación (GPS) del teléfono.');
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        throw const SiteError('La app no tiene permiso de ubicación. Actívalo en los ajustes del teléfono.');
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 25),
        ),
      );
      if (!mounted) return;
      setState(() {
        _s.lat = pos.latitude;
        _s.lng = pos.longitude;
      });
      try {
        _map.move(LatLng(pos.latitude, pos.longitude), 17);
      } catch (_) {
        // El mapa aún no se dibujó: tomará el punto al aparecer.
      }
      toast(context, 'Ubicación tomada (precisión de ±${pos.accuracy.round()} m).');
    } on SiteError catch (e) {
      if (mounted) toast(context, e.message);
    } catch (_) {
      if (mounted) toast(context, 'No se pudo obtener la ubicación. Marca el punto en el mapa.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  // ───────────────────────── Pantalla ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final title = _isNew
        ? (widget.asAdmin ? 'Nuevo sitio' : 'Proponer sitio')
        : (_loading || _loadError != null ? 'Sitio' : 'Editar: ${_s.name}');
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: Text(title),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.navy))
          : (_loadError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_loadError!, textAlign: TextAlign.center),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, c) {
                    final side = ((c.maxWidth - 760) / 2).clamp(16.0, double.infinity);
                    return ListView(
                      padding: EdgeInsets.fromLTRB(side, 16, side, 32),
                      children: _sections(),
                    );
                  },
                )),
      bottomNavigationBar: _loading || _loadError != null ? null : _bottomBar(),
    );
  }

  Widget _bottomBar() {
    final spinner = const SizedBox(
      width: 22,
      height: 22,
      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
    );
    final big = FilledButton.styleFrom(minimumSize: const Size(0, 50));
    final List<Widget> buttons;
    if (widget.asAdmin) {
      buttons = [
        Expanded(
          child: FilledButton(
            style: big,
            onPressed: _busy ? null : () => _save(),
            child: _busy ? spinner : Text(_isNew ? 'Crear sitio' : 'Guardar cambios'),
          ),
        ),
      ];
    } else if (_s.status == 'pending') {
      buttons = [
        Expanded(
          child: FilledButton(
            style: big,
            onPressed: _busy ? null : () => _save(),
            child: _busy ? spinner : const Text('Guardar cambios'),
          ),
        ),
      ];
    } else {
      buttons = [
        Expanded(
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
            onPressed: _busy ? null : () => _save(),
            child: const Text('Guardar borrador'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton(
            style: big,
            onPressed: _busy ? null : () => _save(submit: true),
            child: _busy ? spinner : const Text('Enviar a aprobación'),
          ),
        ),
      ];
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, style: const TextStyle(color: AppColors.danger)),
              ),
            Row(children: buttons),
          ],
        ),
      ),
    );
  }

  List<Widget> _sections() {
    return [
      if (_s.status == 'returned' && (_s.reviewNote ?? '').isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
            ),
            child: Text(
              'El administrador lo devolvió: ${_s.reviewNote}',
              style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      if (!widget.asAdmin && _isNew)
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Text(
            'Registra lo que necesita el sitio. El administrador lo revisa, lo aprueba y asigna a los guardas.',
            style: TextStyle(color: AppColors.muted),
          ),
        ),
      _dataCard(),
      _locationCard(),
      _postsCard(),
      _servicesCard(),
      _contactsCard(),
      _surveyCard(),
    ];
  }

  // ───────────────────────── Datos ─────────────────────────

  Widget _dataCard() {
    final ids = {for (final c in _clients) c.$1};
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: _kNone, child: Text('Sin cliente por ahora')),
      for (final c in _clients) DropdownMenuItem(value: c.$1, child: Text(c.$2)),
      if (_s.clientId != null && !ids.contains(_s.clientId))
        DropdownMenuItem(value: _s.clientId, child: const Text('Cliente actual (inactivo)')),
      const DropdownMenuItem(value: _kNew, child: Text('Cliente nuevo…')),
    ];
    final current = _newClient ? _kNew : (_s.clientId ?? _kNone);
    return FormCard(
      title: 'Datos del sitio',
      children: [
        TextField(
          controller: _ctl(_s, 'name', _s.name),
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Nombre del sitio *', hintText: 'Condominio Las Flores'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ctl(_s, 'address', _s.address),
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Dirección o referencia'),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          // ignore: deprecated_member_use
          value: current,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Cliente'),
          items: items,
          onChanged: (v) => setState(() {
            if (v == _kNew) {
              _newClient = true;
              _s.clientId = null;
            } else {
              _newClient = false;
              _s.clientId = v == _kNone ? null : v;
            }
          }),
        ),
        if (_newClient) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _ctl(_s, 'client', _s.proposedClientName),
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Nombre del cliente nuevo *',
              helperText: widget.asAdmin ? null : 'El administrador lo crea al aprobar el sitio.',
            ),
          ),
        ],
      ],
    );
  }

  // ───────────────────────── Ubicación ─────────────────────────

  Widget _locationCard() {
    final has = _s.lat != null && _s.lng != null;
    final point = has ? LatLng(_s.lat!, _s.lng!) : _guatemala;
    return FormCard(
      title: 'Ubicación y perímetro',
      subtitle: 'Si estás en el sitio, usa tu ubicación. Si no, toca el mapa donde está la garita.',
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _locating ? null : _useMyLocation,
            icon: _locating
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.my_location_rounded),
            label: const Text('Usar mi ubicación'),
          ),
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 280,
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: point,
                initialZoom: has ? 17 : 12,
                onTap: (_, p) => setState(() {
                  _s.lat = p.latitude;
                  _s.lng = p.longitude;
                }),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'app.saasdag',
                ),
                if (has)
                  CircleLayer(
                    circles: [
                      CircleMarker(
                        point: point,
                        radius: _s.radius.toDouble(),
                        useRadiusInMeter: true,
                        color: AppColors.navy.withValues(alpha: 0.15),
                        borderColor: AppColors.navy,
                        borderStrokeWidth: 2,
                      ),
                    ],
                  ),
                if (has)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: point,
                        width: 40,
                        height: 40,
                        child: const Icon(Icons.location_on_rounded, color: AppColors.danger, size: 40),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          has
              ? 'Punto: ${_s.lat!.toStringAsFixed(5)}, ${_s.lng!.toStringAsFixed(5)}'
              : 'Aún no hay punto marcado.',
          style: const TextStyle(color: AppColors.muted, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Text('Perímetro: ${_s.radius} m', style: const TextStyle(fontWeight: FontWeight.w700)),
        Slider(
          value: _s.radius.clamp(20, 1000).toDouble(),
          min: 20,
          max: 1000,
          divisions: 98,
          label: '${_s.radius} m',
          onChanged: (v) => setState(() => _s.radius = v.round()),
        ),
        const Text(
          'El guarda debe estar dentro de este círculo para iniciar turno. '
          'Muy chico da alertas falsas por el GPS; 100 a 150 m suele bastar.',
          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      ],
    );
  }

  // ───────────────────────── Puestos ─────────────────────────

  Widget _postsCard() {
    return FormCard(
      title: 'Puestos',
      subtitle: 'Cada puesto tiene su horario, sus guardas, sus consignas y su inventario. El relevo se hace por puesto.',
      children: [
        for (final p in _s.posts) _postEditor(p),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _s.posts.add(EditPost(name: 'Puesto ${_s.posts.length + 1}'))),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Agregar puesto'),
          ),
        ),
      ],
    );
  }

  Widget _box({required Key key, required List<Widget> children}) {
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  Widget _postEditor(EditPost p) {
    final preset = presetIndexOf(p) ?? _kCustom;
    final guards = _activeGuards;
    return _box(
      key: ObjectKey(p),
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctl(p, 'name', p.name),
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Nombre del puesto *', hintText: 'Garita principal'),
                onChanged: (v) => p.name = v,
              ),
            ),
            if (_s.posts.length > 1)
              IconButton(
                tooltip: 'Quitar puesto',
                onPressed: () => setState(() => _s.posts.remove(p)),
                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
              ),
          ],
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          // ignore: deprecated_member_use
          value: preset,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Horario'),
          items: [
            for (var i = 0; i < schedulePresets.length; i++)
              DropdownMenuItem(value: i, child: Text(schedulePresets[i].label)),
            const DropdownMenuItem(value: _kCustom, child: Text('Personalizado')),
          ],
          onChanged: (v) => setState(() {
            if (v == null || v == _kCustom) {
              // Personalizado: se edita abajo; si coincidía con uno, se mueve un poco para que no lo tome.
              if (presetIndexOf(p) != null) p.coverTo = p.coverTo == '06:00' ? '05:00' : '06:00';
            } else {
              final s = schedulePresets[v];
              p.coverFrom = s.from;
              p.coverTo = s.to;
              p.shiftHours = s.hours;
            }
            _ctl(p, 'from', p.coverFrom).text = p.coverFrom;
            _ctl(p, 'to', p.coverTo).text = p.coverTo;
            _ctl(p, 'hours', '${p.shiftHours}').text = '${p.shiftHours}';
          }),
        ),
        if (preset == _kCustom) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctl(p, 'from', p.coverFrom),
                  keyboardType: TextInputType.datetime,
                  decoration: const InputDecoration(labelText: 'Desde', hintText: '07:00'),
                  onChanged: (v) => p.coverFrom = v.trim(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _ctl(p, 'to', p.coverTo),
                  keyboardType: TextInputType.datetime,
                  decoration: const InputDecoration(labelText: 'Hasta', hintText: '19:00'),
                  onChanged: (v) => p.coverTo = v.trim(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _ctl(p, 'hours', '${p.shiftHours}'),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Horas/turno'),
                  onChanged: (v) => p.shiftHours = int.tryParse(v.trim()) ?? 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text('Si "Desde" y "Hasta" son iguales, el puesto cubre 24 horas.',
              style: TextStyle(color: AppColors.muted, fontSize: 12)),
        ],
        const SizedBox(height: 12),
        const Text('Días', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var d = 1; d <= 7; d++)
              FilterChip(
                label: Text(dayShort[d - 1]),
                selected: p.days.contains(d),
                onSelected: (on) => setState(() => on ? p.days.add(d) : p.days.remove(d)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Expanded(
              child: Text('Guardas requeridos\n(incluye al descansero)',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            IconButton(
              onPressed: p.guardsRequired > 0 ? () => setState(() => p.guardsRequired--) : null,
              icon: const Icon(Icons.remove_circle_outline_rounded),
            ),
            Text('${p.guardsRequired}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            IconButton(
              onPressed: p.guardsRequired < 50 ? () => setState(() => p.guardsRequired++) : null,
              icon: const Icon(Icons.add_circle_outline_rounded),
            ),
          ],
        ),
        if (widget.asAdmin) ...[
          const SizedBox(height: 8),
          Text(
            'Guardas asignados: ${p.guards.length} de ${p.guardsRequired}',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: p.guards.length < p.guardsRequired ? kOrange : AppColors.ink,
            ),
          ),
          const SizedBox(height: 6),
          if (guards.isEmpty)
            const Text('Aún no hay guardas activos en la empresa.', style: TextStyle(color: AppColors.muted))
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final g in guards)
                  FilterChip(
                    label: Text(g.name),
                    selected: p.guards.contains(g.id),
                    onSelected: (on) => setState(() {
                      if (on) {
                        // Un guarda tiene un solo puesto por sitio.
                        for (final o in _s.posts) {
                          o.guards.remove(g.id);
                        }
                        p.guards.add(g.id);
                      } else {
                        p.guards.remove(g.id);
                      }
                    }),
                  ),
              ],
            ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            const Expanded(child: Text('Consignas del puesto', style: TextStyle(fontWeight: FontWeight.w600))),
            if (p.orders.trim().isEmpty)
              TextButton(
                onPressed: () => setState(() {
                  p.orders = ordersTemplate;
                  _ctl(p, 'orders', p.orders).text = ordersTemplate;
                }),
                child: const Text('Usar plantilla'),
              ),
          ],
        ),
        TextField(
          controller: _ctl(p, 'orders', p.orders),
          minLines: 3,
          maxLines: 10,
          maxLength: 4000,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Lo que el guarda debe hacer en este puesto. Lo acepta al iniciar turno.',
          ),
          onChanged: (v) => p.orders = v,
        ),
        const SizedBox(height: 8),
        Text('Implementos (${p.implements.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        for (final i in p.implements) _implRow(p, i),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _addImplement(p),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Agregar implemento'),
          ),
        ),
      ],
    );
  }

  Future<void> _addImplement(EditPost p) async {
    final active = _types.where((t) => t.active).toList();
    if (active.isEmpty) {
      toast(context, 'El catálogo de implementos está vacío.');
      return;
    }
    final t = await showModalBottomSheet<ImplType>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text('Agregar implemento', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              for (final t in active)
                ListTile(
                  leading: Icon(Icons.circle, size: 14, color: sevColor(t.severity)),
                  title: Text(t.name),
                  subtitle: Text('${implTracking[t.tracking] ?? ''} · alerta ${sevLabel(t.severity).toLowerCase()}'),
                  onTap: () => Navigator.of(ctx).pop(t),
                ),
            ],
          ),
        ),
      ),
    );
    if (t == null || !mounted) return;
    setState(() => p.implements.add(EditImplement(typeId: t.id)));
  }

  Widget _implRow(EditPost p, EditImplement i) {
    final t = _type(i.typeId);
    final tracking = t?.tracking ?? 'unit';
    return Container(
      key: ObjectKey(i),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 12, color: sevColor(t?.severity)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(t?.name ?? 'Implemento', style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              if (i.status != 'ok') Pill(implStatusLabel(i.status), i.status == 'missing' ? AppColors.danger : kOrange),
              IconButton(
                tooltip: 'Quitar',
                onPressed: () => setState(() => p.implements.remove(i)),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctl(i, 'label', i.label),
                    decoration: const InputDecoration(labelText: 'Descripción', hintText: 'Marca, modelo…', isDense: true),
                    onChanged: (v) => i.label = v,
                  ),
                ),
                if (tracking == 'serial') ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _ctl(i, 'serial', i.serial),
                      decoration: const InputDecoration(labelText: 'No. de serie', isDense: true),
                      onChanged: (v) => i.serial = v,
                    ),
                  ),
                ],
                if (tracking == 'count') ...[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 96,
                    child: TextField(
                      controller: _ctl(i, 'qty', '${i.quantity}'),
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Cantidad', isDense: true),
                      onChanged: (v) => i.quantity = int.tryParse(v.trim()) ?? 0,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if ((i.statusNote ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 8),
              child: Text('Último reporte: ${i.statusNote}',
                  style: const TextStyle(color: AppColors.muted, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  // ───────────────────────── Servicios ─────────────────────────

  Widget _servicesCard() {
    final options = {..._roundOptions, _s.roundsEvery}.toList()..sort();
    return FormCard(
      title: 'Servicios del sitio',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _s.roundsRequired,
          onChanged: (v) => setState(() => _s.roundsRequired = v),
          title: const Text('Rondas con QR'),
          subtitle: const Text('Los puntos de control se registran en el módulo de rondas.'),
        ),
        if (_s.roundsRequired)
          DropdownButtonFormField<int>(
            // ignore: deprecated_member_use
            value: _s.roundsEvery,
            decoration: const InputDecoration(labelText: 'Frecuencia de las rondas'),
            items: [for (final m in options) DropdownMenuItem(value: m, child: Text(_everyLabel(m)))],
            onChanged: (v) => setState(() => _s.roundsEvery = v ?? 120),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _s.visitorControl,
          onChanged: (v) => setState(() => _s.visitorControl = v),
          title: const Text('Control de visitas'),
          subtitle: const Text('Módulo de pago: solo funciona si la empresa lo tiene activo.'),
        ),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.menu_book_rounded, color: AppColors.navy),
          title: Text('Bitácora de novedades'),
          subtitle: Text('Siempre activa en todos los sitios.'),
        ),
      ],
    );
  }

  // ───────────────────────── Administradores del cliente ─────────────────────────

  Widget _contactsCard() {
    return FormCard(
      title: 'Administradores y contactos del cliente',
      subtitle: 'A quiénes capacita el supervisor. Después podrán entrar al portal del cliente.',
      children: [
        for (final c in _s.contacts) _contactEditor(c),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _s.contacts.add(EditContact())),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: const Text('Agregar administrador o contacto'),
          ),
        ),
      ],
    );
  }

  Widget _contactEditor(EditContact c) {
    final trained = _ctl(c, 'trained', c.trainedAt == null ? '' : fmtDate(c.trainedAt!));
    return _box(
      key: ObjectKey(c),
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctl(c, 'name', c.name),
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Nombre *'),
                onChanged: (v) => c.name = v,
              ),
            ),
            IconButton(
              tooltip: 'Quitar',
              onPressed: () => setState(() => _s.contacts.remove(c)),
              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _ctl(c, 'job', c.jobTitle),
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Cargo', hintText: 'Administrador, Junta directiva, Conserje…'),
          onChanged: (v) => c.jobTitle = v,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctl(c, 'phone', c.phone),
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Teléfono'),
                onChanged: (v) => c.phone = v,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _ctl(c, 'email', c.email),
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Correo'),
                onChanged: (v) => c.email = v,
              ),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: c.isAdmin,
          onChanged: (v) => setState(() => c.isAdmin = v),
          title: const Text('Es administrador del cliente'),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: trained,
                keyboardType: TextInputType.datetime,
                decoration: const InputDecoration(labelText: 'Capacitación dada el', hintText: 'dd/mm/aaaa'),
                onChanged: (v) => c.trainedAt = v.trim().isEmpty ? null : parseDmy(v.trim()),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => setState(() {
                c.trainedAt = todayDate();
                trained.text = fmtDate(c.trainedAt!);
              }),
              child: const Text('Hoy'),
            ),
          ],
        ),
      ],
    );
  }

  // ───────────────────────── Levantamiento ─────────────────────────

  Widget _surveyCard() {
    final n = surveyAnswered(_s.survey);
    return FormCard(
      title: 'Levantamiento de seguridad',
      subtitle: '$n de ${surveyQuestions.length} respondidas. Ayuda a decidir guardas, armas y rondas, y prepara al descansero que no conoce el sitio.',
      children: [
        for (final q in surveyQuestions)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(q.label, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                if (q.isText)
                  TextField(
                    controller: _ctl(_s.survey, q.key, surveyValueText(_s.survey[q.key])),
                    textCapitalization: TextCapitalization.sentences,
                    minLines: q.key == 'observaciones' ? 2 : 1,
                    maxLines: q.key == 'observaciones' ? 6 : 2,
                    onChanged: (v) => _s.survey[q.key] = v,
                  )
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final o in q.options)
                        q.multi
                            ? FilterChip(
                                label: Text(o),
                                selected: _multi(q.key).contains(o),
                                onSelected: (on) => setState(() {
                                  final l = _multi(q.key);
                                  on ? l.add(o) : l.remove(o);
                                  _s.survey[q.key] = l;
                                }),
                              )
                            : ChoiceChip(
                                label: Text(o),
                                selected: _s.survey[q.key] == o,
                                onSelected: (on) => setState(() {
                                  if (on) {
                                    _s.survey[q.key] = o;
                                  } else {
                                    _s.survey.remove(q.key);
                                  }
                                }),
                              ),
                    ],
                  ),
              ],
            ),
          ),
      ],
    );
  }

  List<String> _multi(String key) {
    final v = _s.survey[key];
    return v is List ? [for (final x in v) x.toString()] : <String>[];
  }
}
