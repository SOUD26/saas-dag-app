import 'package:flutter/material.dart';

import '../../supabase.dart';
import '../../theme.dart';
import '../admin/admin_data.dart' show AdminData;
import '../admin/admin_ui.dart' show Panel, Pill, toast;
import '../admin/staff_file.dart' show fmtDate;
import 'site_data.dart';
import 'site_form.dart';
import 'visit_history.dart';
import 'visitor_photos.dart';
import '../guard/readers.dart' show fmtPlate;

/// Ficha del sitio. El administrador aprueba, devuelve, edita y activa/desactiva.
/// El supervisor ve sus sitios y edita sus propuestas mientras no estén aprobadas.
Future<void> openSiteDetail(
  BuildContext context, {
  required String siteId,
  required bool asAdmin,
  AdminData? d,
  Future<void> Function()? reload,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => SiteDetailPage(siteId: siteId, asAdmin: asAdmin, d: d, reload: reload),
    ),
  );
}

class SiteDetailPage extends StatefulWidget {
  const SiteDetailPage({super.key, required this.siteId, required this.asAdmin, this.d, this.reload});
  final String siteId;
  final bool asAdmin;
  final AdminData? d;
  final Future<void> Function()? reload;

  @override
  State<SiteDetailPage> createState() => _SiteDetailPageState();
}

class _SiteDetailPageState extends State<SiteDetailPage> {
  SiteFull? _s;
  List<ImplType> _types = [];
  String? _error;
  bool _busy = false;
  List<Map<String, dynamic>> _inside = [];
  List<Map<String, dynamic>> _entries = [];
  List<Map<String, dynamic>> _log = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await loadSiteFull(widget.siteId);
      final types = await loadImplTypes(companyId: s.companyId);
      var inside = <Map<String, dynamic>>[];
      var entries = <Map<String, dynamic>>[];
      var log = <Map<String, dynamic>>[];
      if (s.approved) {
        try {
          if (s.visitorControl) {
            final rows = await supabase.rpc('site_inside', params: {'p_site_id': widget.siteId});
            inside = [for (final r in (rows as List<dynamic>)) Map<String, dynamic>.from(r as Map)];
            entries = await supabase
                .from('access_entries')
                .select('id, kind, plate, person_name, doc_kind, doc_number, visitor_company_text, '
                    'visitor_companies(name), destination, status, entered_at, exited_at, entry_offline, doc_photo_path')
                .eq('site_id', widget.siteId)
                .order('entered_at', ascending: false)
                .limit(30);
          }
          log = await supabase
              .from('site_log')
              .select('id, category, body, happened_at, offline, author_id, profiles(full_name)')
              .eq('site_id', widget.siteId)
              .order('happened_at', ascending: false)
              .limit(20);
        } catch (_) {
          // La ficha se muestra igual, sin la actividad.
        }
      }
      if (!mounted) return;
      setState(() {
        _s = s;
        _types = types;
        _inside = inside;
        _entries = entries;
        _log = log;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'No se pudo cargar el sitio. Revisa tu conexión.');
    }
  }

  Future<void> _afterChange() async {
    await widget.reload?.call();
    await _load();
  }

  ImplType? _type(String id) {
    for (final t in _types) {
      if (t.id == id) return t;
    }
    return null;
  }

  bool get _mine => _s?.proposedBy != null && _s?.proposedBy == supabase.auth.currentUser?.id;

  bool get _canEdit {
    final s = _s;
    if (s == null) return false;
    return widget.asAdmin || (_mine && !s.approved);
  }

  Future<void> _edit() async {
    final s = _s;
    if (s == null) return;
    final saved = await openSiteForm(
      context,
      asAdmin: widget.asAdmin,
      siteId: s.id,
      companyId: s.companyId,
      guards: widget.d?.guards ?? const [],
    );
    if (saved == true) await _afterChange();
  }

  Future<void> _run(Future<void> Function() job, String done) async {
    setState(() => _busy = true);
    try {
      await job();
      if (!mounted) return;
      toast(context, done);
      await _afterChange();
    } on SiteError catch (e) {
      if (mounted) toast(context, e.message);
    } catch (_) {
      if (mounted) toast(context, 'No se pudo completar. Revisa tu conexión.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() async {
    final s = _s;
    if (s == null || s.id == null) return;
    final assigned = s.posts.fold<int>(0, (n, p) => n + p.guards.length);
    String? clientId = s.clientId;
    String? newName;

    if (s.clientId == null) {
      List<(String, String)> clients = const [];
      try {
        clients = await loadClientOptions(s.companyId);
      } catch (_) {
        // Sin la lista, igual se puede crear el cliente propuesto.
      }
      if (!mounted) return;
      final hasProposal = s.proposedClientName.trim().isNotEmpty;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('¿De qué cliente es este sitio?'),
          children: [
            if (hasProposal)
              SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop('__new__'),
                child: Text('Crear el cliente «${s.proposedClientName.trim()}»',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            for (final c in clients)
              SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(c.$1),
                child: Text(c.$2),
              ),
            if (!hasProposal)
              SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop('__none__'),
                child: const Text('Sin cliente por ahora'),
              ),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == '__new__') {
        newName = s.proposedClientName.trim();
      } else if (choice != '__none__') {
        clientId = choice;
      }
    }

    if (assigned == 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Aún no hay guardas asignados'),
          content: const Text(
              'Sin guardas asignados nadie podrá iniciar turno en este sitio. Puedes asignarlos con "Editar" antes o después de aprobar.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Aprobar igual')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _run(
      () => approveSite(s.id!, clientId: clientId, newClientName: newName),
      'Sitio aprobado y activo.',
    );
  }

  Future<void> _return() async {
    final s = _s;
    if (s == null || s.id == null) return;
    final ctl = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Devolver al supervisor'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: '¿Qué debe corregir o completar?'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(ctl.text.trim()), child: const Text('Devolver')),
        ],
      ),
    );
    ctl.dispose();
    if (note == null || note.isEmpty) return;
    await _run(() => returnSite(s.id!, note), 'Devuelto al supervisor con tus observaciones.');
  }

  Future<void> _toggleActive() async {
    final s = _s;
    if (s == null || s.id == null) return;
    if (s.active) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('¿Desactivar el sitio?'),
          content: const Text('Nadie podrá iniciar turno ni hacer relevo aquí. Su historial se conserva.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Desactivar')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _run(() => setSiteActive(s.id!, !s.active), s.active ? 'Sitio desactivado.' : 'Sitio activado.');
  }

  // ───────────────────────── Pantalla ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: Text(s?.name ?? 'Sitio'),
        actions: [
          if (_canEdit)
            IconButton(tooltip: 'Editar', onPressed: _busy ? null : _edit, icon: const Icon(Icons.edit_rounded)),
        ],
      ),
      body: s == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator(color: AppColors.navy)
                  : Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)),
            )
          : LayoutBuilder(
              builder: (context, c) {
                final side = ((c.maxWidth - 760) / 2).clamp(16.0, double.infinity);
                return RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(side, 16, side, 32),
                    children: _body(s),
                  ),
                );
              },
            ),
      bottomNavigationBar: s == null ? null : _actions(s),
    );
  }

  Widget? _actions(SiteFull s) {
    final buttons = <Widget>[];
    if (widget.asAdmin) {
      if (s.status == 'pending') {
        buttons.addAll([
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
              onPressed: _busy ? null : _return,
              child: const Text('Devolver'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
              onPressed: _busy ? null : _approve,
              child: const Text('Aprobar'),
            ),
          ),
        ]);
      } else if (s.approved) {
        buttons.addAll([
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
              onPressed: _busy ? null : _toggleActive,
              child: Text(s.active ? 'Desactivar' : 'Activar'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
              onPressed: _busy ? null : _edit,
              child: const Text('Editar y asignar guardas'),
            ),
          ),
        ]);
      }
    } else if (_canEdit) {
      buttons.add(
        Expanded(
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
            onPressed: _busy ? null : _edit,
            child: Text(s.status == 'pending' ? 'Editar propuesta' : 'Completar y enviar'),
          ),
        ),
      );
    }
    if (buttons.isEmpty) return null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(children: buttons),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 120, child: Text(k, style: const TextStyle(color: AppColors.muted, fontSize: 13))),
            Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
          ],
        ),
      );

  Widget _card(String title, List<Widget> children, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  ),
                  if (trailing != null) trailing,
                ],
              ),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );

  String _clientText(SiteFull s) {
    if (s.clientId != null) {
      final d = widget.d;
      if (d != null) return d.clientName(s.clientId);
      return 'Asignado';
    }
    if (s.proposedClientName.trim().isNotEmpty) return '${s.proposedClientName.trim()} (nuevo, se crea al aprobar)';
    return 'Sin cliente';
  }

  List<Widget> _body(SiteFull s) {
    final d = widget.d;
    final answered = [
      for (final q in surveyQuestions)
        if (surveyValueText(s.survey[q.key]).trim().isNotEmpty) (q.label, surveyValueText(s.survey[q.key])),
    ];
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          Pill(siteStatusLabel(s.status), siteStatusColor(s.status)),
          if (s.approved && !s.active) const Pill('Inactivo', AppColors.muted),
        ],
      ),
      const SizedBox(height: 12),
      if (s.status == 'returned' && (s.reviewNote ?? '').isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text('Devuelto: ${s.reviewNote}',
              style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w600)),
        ),
      if (widget.asAdmin && s.status == 'pending')
        const Padding(
          padding: EdgeInsets.only(bottom: 14),
          child: Text(
            'Propuesta del supervisor. Revísala, asigna guardas con "Editar" si quieres, y apruébala o devuélvela.',
            style: TextStyle(color: AppColors.muted),
          ),
        ),
      _card('Datos', [
        _row('Cliente', _clientText(s)),
        if (s.address.trim().isNotEmpty) _row('Dirección', s.address),
        _row('Perímetro', '${s.radius} m'),
        if (s.lat != null && s.lng != null) _row('Ubicación', '${s.lat!.toStringAsFixed(5)}, ${s.lng!.toStringAsFixed(5)}'),
        _row('Rondas con QR', s.roundsRequired ? 'Sí · ${_every(s.roundsEvery)}' : 'No'),
        _row('Control de visitas', s.visitorControl ? 'Sí' : 'No'),
        _row('Bitácora', 'Siempre activa'),
      ]),
      for (final p in s.posts)
        _card(
          p.name,
          [
            _row('Horario', scheduleText(p)),
            _row(
              'Guardas',
              d == null
                  ? '${p.guardsRequired} requeridos'
                  : '${p.guards.length} de ${p.guardsRequired} asignados'
                      '${p.guards.isEmpty ? '' : ': ${p.guards.map(d.guardName).join(', ')}'}',
            ),
            if (p.orders.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              const Text('Consignas', style: TextStyle(color: AppColors.muted, fontSize: 13)),
              Text(p.orders),
            ],
            const SizedBox(height: 8),
            Text('Implementos (${p.implements.length})', style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            if (p.implements.isEmpty)
              const Text('Sin implementos registrados.')
            else
              for (final i in p.implements) _implLine(i),
          ],
          trailing: d != null && p.guards.length < p.guardsRequired
              ? Pill('Faltan ${p.guardsRequired - p.guards.length}', kOrange)
              : null,
        ),
      if (s.approved && s.visitorControl) _entriesCard(s),
      if (s.approved) _logCard(),
      _card('Administradores y contactos del cliente', [
        if (s.contacts.isEmpty) const Text('Sin contactos registrados.', style: TextStyle(color: AppColors.muted)),
        for (final c in s.contacts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${c.name}${c.jobTitle.trim().isEmpty ? '' : ' · ${c.jobTitle}'}${c.isAdmin ? ' · administrador' : ''}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                if (c.phone.isNotEmpty || c.email.isNotEmpty)
                  Text([c.phone, c.email].where((x) => x.isNotEmpty).join(' · ')),
                Text(
                  c.trainedAt == null ? 'Capacitación pendiente' : 'Capacitado el ${fmtDate(c.trainedAt!)}',
                  style: TextStyle(color: c.trainedAt == null ? kOrange : AppColors.muted, fontSize: 13),
                ),
              ],
            ),
          ),
      ]),
      _card(
        'Levantamiento de seguridad',
        [
          if (answered.isEmpty)
            const Text('Aún sin responder.', style: TextStyle(color: AppColors.muted))
          else
            for (final a in answered) _row(a.$1, a.$2),
        ],
        trailing: Text('${answered.length} de ${surveyQuestions.length}',
            style: const TextStyle(color: AppColors.muted, fontSize: 13)),
      ),
    ];
  }

  String _hm(String iso) {
    final d = DateTime.parse(iso).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final today = d.year == now.year && d.month == now.month && d.day == now.day;
    return today ? '${two(d.hour)}:${two(d.minute)}' : '${two(d.day)}/${two(d.month)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _entriesCard(SiteFull s) {
    String title(Map<String, dynamic> e) {
      final plate = e['plate'] as String?;
      final name = e['person_name'] as String?;
      return [if (plate != null && plate.isNotEmpty) fmtPlate(plate), if (name != null && name.isNotEmpty) name].join(' · ');
    }

    String company(Map<String, dynamic> e) =>
        ((e['visitor_companies'] as Map?)?['name'] as String?) ?? (e['visitor_company_text'] as String?) ?? (e['company_name'] as String?) ?? '';
    return _card(
      'Ingresos y salidas',
      [
        Text('Dentro ahora: ${_inside.length}', style: const TextStyle(fontWeight: FontWeight.w800)),
        for (final e in _inside.take(10))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Text('${title(e)}${company(e).isEmpty ? '' : ' · ${company(e)}'} · entró ${_hm(e['entered_at'] as String)}'),
          ),
        const SizedBox(height: 10),
        const Text('Últimos registros', style: TextStyle(color: AppColors.muted, fontSize: 13)),
        if (_entries.isEmpty) const Text('Aún no hay ingresos.', style: TextStyle(color: AppColors.muted)),
        for (final e in _entries)
          InkWell(
            onTap: () => openVisitHistory(
              context,
              companyId: s.companyId,
              query: (e['doc_number'] as String?) ?? (e['plate'] as String?) ?? (e['person_name'] as String?),
              canSeePhotos: widget.asAdmin,
            ),
            child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${title(e)}${company(e).isEmpty ? '' : ' · ${company(e)}'}\n'
                    'Entró ${_hm(e['entered_at'] as String)}'
                    '${e['exited_at'] != null ? ' · salió ${_hm(e['exited_at'] as String)}' : ' · dentro'}'
                    '${e['entry_offline'] == true ? ' · registrado sin señal' : ''}',
                  ),
                ),
                if (widget.asAdmin && e['doc_photo_path'] != null)
                  IconButton(
                    tooltip: 'Ver foto del documento',
                    onPressed: () async {
                      final deleted = await showVisitorPhoto(context, e);
                      if (deleted) await _load();
                    },
                    icon: const Icon(Icons.badge_rounded, color: AppColors.navy),
                  ),
              ],
            ),
          ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => openVisitHistory(
              context,
              companyId: s.companyId,
              siteId: s.id,
              canSeePhotos: widget.asAdmin,
              title: 'Historial · ${s.name}',
            ),
            icon: const Icon(Icons.manage_search_rounded),
            label: const Text('Historial de visitas de este sitio'),
          ),
        ),
        if (widget.asAdmin && s.companyId != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => openVisitorPhotos(context, companyId: s.companyId!, siteId: s.id, title: 'Fotos · ${s.name}'),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Fotos de documentos de este sitio'),
            ),
          ),
      ],
      trailing: Pill('${_inside.length} dentro', _inside.isEmpty ? AppColors.muted : AppColors.navy),
    );
  }

  String _author(Map<String, dynamic> l, AdminData? d) {
    final name = (l['profiles'] as Map?)?['full_name'] as String?;
    if (name != null && name.isNotEmpty) return ' · $name';
    final id = l['author_id'] as String?;
    if (id == null || d == null) return '';
    return ' · ${d.guardName(id)}';
  }

  Widget _logCard() {
    const labels = {
      'sin_novedad': 'Sin novedad',
      'novedad': 'Novedad',
      'incidente': 'Incidente',
      'mantenimiento': 'Mantenimiento',
      'visita_supervisor': 'Visita del supervisor',
    };
    final d = widget.d;
    return _card('Bitácora de novedades', [
      if (_log.isEmpty) const Text('Sin anotaciones recientes.', style: TextStyle(color: AppColors.muted)),
      for (final l in _log)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            '${_hm(l['happened_at'] as String)} · ${labels[l['category']] ?? l['category']}'
            '${_author(l, d)}'
            '${l['offline'] == true ? ' · sin señal' : ''}'
            '${(l['body'] as String?)?.isNotEmpty == true ? '\n${l['body']}' : ''}',
            style: TextStyle(
              color: l['category'] == 'incidente' ? AppColors.danger : AppColors.ink,
              fontWeight: l['category'] == 'incidente' ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
    ]);
  }

  String _every(int m) => m % 60 == 0 ? 'cada ${m ~/ 60} h' : 'cada $m min';

  Widget _implLine(EditImplement i) {
    final t = _type(i.typeId);
    final extra = [
      if (i.label.isNotEmpty) i.label,
      if (i.serial.isNotEmpty) 'serie ${i.serial}',
      if (t?.tracking == 'count') '${i.quantity} unidades',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: sevColor(t?.severity)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${t?.name ?? 'Implemento'}${extra.isEmpty ? '' : ' · $extra'}',
            ),
          ),
          if (i.status != 'ok')
            Pill(implStatusLabel(i.status), i.status == 'missing' ? AppColors.danger : kOrange),
        ],
      ),
    );
  }
}
