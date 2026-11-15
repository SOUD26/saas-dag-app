import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/profile.dart';
import '../../supabase.dart';
import 'guard_checklist.dart';
import 'guard_entry.dart';
import 'guard_inside.dart';
import 'guard_log.dart';
import 'guard_session.dart';
import 'guard_store.dart';
import 'guard_ui.dart';
import 'readers.dart' show newId;

/// Pantalla del guarda. Funciona sin señal: lo que hace se guarda en el teléfono y se envía solo.
class GuardHome extends StatefulWidget {
  const GuardHome({super.key, required this.profile});
  final Profile profile;

  @override
  State<GuardHome> createState() => _GuardHomeState();
}

class _GuardHomeState extends State<GuardHome> with WidgetsBindingObserver {
  GuardSession? _s;
  bool _loading = true;
  bool _closing = false;
  Timer? _timer;
  String? _photoUrl;
  String? _photoFor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _s?.removeListener(_changed);
    _s?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _s?.refresh();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _open() async {
    final store = await GuardStore.open(widget.profile.id);
    final s = GuardSession(store, widget.profile)..addListener(_changed);
    if (!mounted) return;
    setState(() => _s = s);
    await s.refresh();
    if (!mounted) return;
    setState(() => _loading = false);
    _timer = Timer.periodic(const Duration(seconds: 45), (_) => _tick());
  }

  Future<void> _tick() async {
    final s = _s;
    if (s == null) return;
    final last = s.lastRefresh;
    if (last == null || DateTime.now().difference(last).inMinutes >= 10) {
      await s.refresh();
    } else {
      await s.sync();
    }
    if (_closing && s.pending == 0) await _signOut();
  }

  Future<void> _signOut() async {
    _timer?.cancel();
    await supabase.auth.signOut();
  }

  // ───────────────────────── Iniciar turno ─────────────────────────

  Future<({double? lat, double? lng})> _locate() async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => guardFrame(
        ctx,
        const Dialog(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: gNavy),
                SizedBox(height: 18),
                Text('Buscando su ubicación…', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
      ),
    );
    double? lat;
    double? lng;
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      final allowed = perm != LocationPermission.denied && perm != LocationPermission.deniedForever;
      if (allowed && await Geolocator.isLocationServiceEnabled()) {
        final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
        );
        lat = p.latitude;
        lng = p.longitude;
      }
    } catch (_) {
      // Sin GPS: el servidor lo marca como alerta "sin GPS".
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    return (lat: lat, lng: lng);
  }

  Future<Map<String, dynamic>?> _choosePost(List<Map<String, dynamic>> posts) {
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => guardFrame(
        ctx,
        Dialog(
          insetPadding: const EdgeInsets.all(18),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const GuardTitle('¿En qué puesto está?'),
                for (final p in posts)
                  GuardButton(
                    icon: Icons.shield_rounded,
                    label: p['name'] as String? ?? 'Puesto',
                    color: gNavy,
                    height: 76,
                    onTap: () => Navigator.of(ctx).pop(p),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _startShift() async {
    final s = _s;
    final site = s?.site;
    if (s == null || site == null) return;
    final posts = s.posts;
    if (posts.isEmpty) {
      await showDone(context,
          title: 'Este sitio no tiene puestos', sub: 'Llame a su supervisor.', color: gOrange, icon: Icons.info_rounded);
      return;
    }
    var post = s.myPost ?? posts.first;
    if (posts.length > 1) {
      final chosen = await _choosePost(posts);
      if (chosen == null || !mounted) return;
      post = chosen;
    }
    final siteId = site['site_id'] as String;

    // 1. Llegada con GPS (sin cara mientras no exista el reconocimiento facial).
    if (!s.store.recentlyVerified(siteId)) {
      final pos = await _locate();
      if (!mounted) return;
      final id = newId();
      await s.enqueue(GuardOp(
        id: id,
        kind: 'verification',
        label: 'Inicio de turno',
        at: DateTime.now(),
        params: {
          'p_client_id': id,
          'p_site_id': siteId,
          'p_device_id': null,
          'p_kind': 'shift_start',
          'p_method': 'password_fallback',
          'p_face_score': null,
          'p_matched_guard_id': null,
          'p_lat': pos.lat,
          'p_lng': pos.lng,
          'p_fallback_reason': 'reconocimiento facial no instalado',
          'p_photo_path': null,
          'p_happened_at': DateTime.now().toUtc().toIso8601String(),
        },
      ));
      await s.store.markVerified(siteId);
      unawaited(s.sync());
    }
    if (!mounted) return;

    // 2. Consignas del puesto.
    var ordersSeen = false;
    final orders = ((post['orders'] as String?) ?? '').trim();
    if (orders.isNotEmpty) {
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => _OrdersPage(postName: post['name'] as String? ?? 'Puesto', orders: orders)),
      );
      if (ok != true || !mounted) return;
      ordersSeen = true;
    }

    // 3. Recibir el puesto.
    final received = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => GuardChecklistPage(session: s, post: post, kind: 'reception', ordersSeen: ordersSeen),
      ),
    );
    if (received == true) {
      await s.store.setDuty(post['id'] as String);
      _changed();
    }
  }

  // ───────────────────────── Entregar y salir ─────────────────────────

  Future<void> _deliver() async {
    final s = _s;
    final post = s?.dutyPost;
    if (s == null || post == null) return;
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => GuardChecklistPage(session: s, post: post, kind: 'delivery')),
    );
    if (ok != true || !mounted) return;
    await s.store.setDuty(null);
    _changed();
    if (!mounted) return;
    final close = await askYesNo(context, '¿Terminó su turno?',
        sub: 'Cierre sesión para que el siguiente guarda entre con su usuario.',
        yes: 'Sí, cerrar sesión',
        no: 'No, sigo aquí');
    if (close) await _closeSession();
  }

  Future<void> _closeSession() async {
    final s = _s;
    if (s == null) return;
    if (s.onDuty) {
      final deliver = await askYesNo(context, 'Todavía tiene el puesto',
          sub: 'Antes de salir, entregue el puesto.', yes: 'Entregar el puesto', no: 'Cancelar', color: gRed);
      if (deliver) await _deliver();
      return;
    }
    await s.sync();
    if (!mounted) return;
    if (s.pending == 0) {
      await _signOut();
      return;
    }
    final wait = await askYesNo(context, 'Hay ${s.pending} registros sin enviar',
        sub: 'Se envían solos cuando haya señal, pero solo con su usuario. Lo mejor es esperar con la app abierta.',
        yes: 'Esperar la señal',
        no: 'Salir igual',
        color: gAmber);
    if (wait) {
      setState(() => _closing = true);
    } else {
      await _signOut();
    }
  }

  Future<void> _call(String phone) async {
    try {
      await launchUrl(Uri(scheme: 'tel', path: phone));
    } catch (_) {
      if (mounted) await showDone(context, title: 'Llame al $phone', color: gNavy, icon: Icons.phone_rounded);
    }
  }

  Future<void> _photo(String? path) async {
    if (path == null || path == _photoFor) return;
    _photoFor = path;
    try {
      final url = await supabase.storage.from('avatars').createSignedUrl(path, 3600);
      if (mounted) setState(() => _photoUrl = url);
    } catch (_) {
      _photoFor = null; // se reintenta cuando haya señal
    }
  }

  // ───────────────────────── Pantalla ─────────────────────────

  Widget _simple(String title, String sub, {List<Widget> extra = const []}) {
    return GuardPage(
      title: 'Guarda',
      children: [
        GuardTitle(title, sub: sub),
        ...extra,
        GuardButton(icon: Icons.refresh_rounded, label: 'Reintentar', color: gNavy, onTap: () => _s?.refresh()),
        GuardButton(icon: Icons.logout_rounded, label: 'Cerrar sesión', color: gSoft, onTap: _signOut),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null || (_loading && s.ctx == null)) {
      return guardFrame(context, const Scaffold(body: Center(child: CircularProgressIndicator(color: gNavy))));
    }
    if (s.ctx == null) {
      return _simple('Necesita señal', 'La primera vez el teléfono debe tener internet para bajar sus datos. Después funciona sin señal.');
    }
    if (s.sites.isEmpty) {
      return _simple('No tiene sitio asignado', 'Llame a su supervisor para que lo asignen a un sitio.');
    }
    final site = s.site;
    if (site == null) {
      return GuardPage(
        title: 'Elija su sitio',
        children: [
          GuardTitle('¿Dónde está hoy?', sub: 'Hola, ${widget.profile.firstName}'),
          for (final x in s.sites)
            GuardButton(
              icon: Icons.place_rounded,
              label: x['name'] as String? ?? 'Sitio',
              sub: x['address'] as String?,
              color: gNavy,
              onTap: () => s.chooseSite(x['site_id'] as String),
            ),
        ],
      );
    }
    if (_closing) {
      return GuardPage(
        title: 'Cerrando sesión',
        children: [
          GuardTitle('Esperando señal…',
              sub: 'Faltan ${s.pending} registros por enviar. Deje la app abierta: cuando haya señal se envían y se cierra la sesión sola.'),
          const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(color: gNavy))),
          GuardButton(icon: Icons.sync_rounded, label: 'Intentar ahora', color: gNavy, onTap: _tick),
          GuardButton(icon: Icons.logout_rounded, label: 'Salir igual', color: gSoft, onTap: _signOut),
        ],
      );
    }

    final duty = s.dutyPost;
    final shift = s.shift;
    final sup = s.supervisors.isEmpty ? null : s.supervisors.first;
    if (sup != null && s.online) _photo(sup['avatar_path'] as String?);
    final inside = s.visitorControl ? s.store.inside(site['site_id'] as String).length : 0;

    return GuardPage(
      title: site['name'] as String? ?? 'Sitio',
      actions: [
        IconButton(tooltip: 'Cerrar sesión', onPressed: _closeSession, icon: const Icon(Icons.logout_rounded, size: 30)),
      ],
      children: [
        GuardCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Hola, ${widget.profile.firstName}', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text(
                duty != null
                    ? 'En turno en ${duty['name']}${s.store.dutySince != null ? ' desde las ${hhmm(s.store.dutySince!)}' : ''}'
                    : (shift != null
                        ? 'Su turno: ${hhmm(DateTime.parse(shift['starts_at'] as String))} a ${hhmm(DateTime.parse(shift['ends_at'] as String))}'
                        : 'Aún no ha iniciado turno'),
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: duty != null ? gGreen : gSoft),
              ),
            ],
          ),
        ),
        _syncCard(s),
        if (duty == null)
          GuardButton(
            icon: Icons.login_rounded,
            label: 'Iniciar turno',
            sub: 'Recibir el puesto y revisar el equipo',
            color: gGreen,
            height: 110,
            onTap: _startShift,
          ),
        if (duty != null && s.visitorControl) ...[
          GuardButton(
            icon: Icons.add_circle_rounded,
            label: 'Ingreso',
            sub: 'Placa y documento con foto',
            color: gBlue,
            height: 104,
            onTap: () async {
              await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => GuardEntryPage(session: s)));
              _changed();
            },
          ),
          GuardButton(
            icon: Icons.exit_to_app_rounded,
            label: 'Salida',
            sub: inside == 1 ? '1 está dentro' : '$inside están dentro',
            color: gNavy,
            height: 104,
            onTap: () async {
              await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => GuardInsidePage(session: s)));
              _changed();
            },
          ),
        ],
        GuardButton(
          icon: Icons.menu_book_rounded,
          label: 'Novedad',
          sub: 'Anotar en la bitácora',
          color: gAmber,
          onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => GuardLogPage(session: s))),
        ),
        if (duty != null)
          GuardButton(
            icon: Icons.logout_rounded,
            label: 'Entregar puesto',
            sub: 'Al terminar su turno',
            color: gRed,
            onTap: _deliver,
          ),
        if (sup != null) _supervisorCard(sup),
        for (final d in s.docs)
          GuardCard(
            color: const Color(0xFFFFF4E5),
            border: gOrange,
            child: Text(
              '${d['name']}: ${d['status'] == 'missing' ? 'falta entregarlo' : (d['status'] == 'expired' ? 'vencido' : 'vence pronto')}. Avise a su supervisor.',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: gAmber),
            ),
          ),
        if (s.sites.length > 1 && duty == null)
          TextButton(
            onPressed: () => s.store.setSiteId(null).then((_) => _changed()),
            child: const Text('Cambiar de sitio', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          ),
      ],
    );
  }

  Widget _syncCard(GuardSession s) {
    final pending = s.pending;
    final bad = s.rejectedCount;
    if (bad > 0) {
      return GuardCard(
        color: const Color(0xFFFDECEA),
        border: gRed,
        child: InkWell(
          onTap: _showRejected,
          child: Text('$bad registros no se aceptaron. Toque aquí y avise a su supervisor.',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: gRed)),
        ),
      );
    }
    if (pending > 0) {
      return GuardCard(
        color: const Color(0xFFFFF4E5),
        border: gAmber,
        child: InkWell(
          onTap: () => s.sync(),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_rounded, color: gAmber, size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  pending == 1 ? '1 registro por enviar. Se envía solo cuando haya señal.' : '$pending registros por enviar. Se envían solos cuando haya señal.',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: gAmber),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return GuardCard(
      color: const Color(0xFFE8F5E9),
      border: gGreen,
      child: Row(
        children: [
          Icon(s.online ? Icons.cloud_done_rounded : Icons.cloud_off_rounded, color: gGreen, size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Text(s.online ? 'Todo enviado' : 'Sin señal · nada pendiente',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: gGreen)),
          ),
        ],
      ),
    );
  }

  Future<void> _showRejected() async {
    final s = _s;
    if (s == null) return;
    final list = s.store.rejected;
    await showDialog<void>(
      context: context,
      builder: (ctx) => guardFrame(
        ctx,
        AlertDialog(
          title: const Text('No se aceptaron', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final o in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text('${dayHhmm(o.at)} · ${o.label}\n${o.error ?? ''}', style: const TextStyle(fontSize: 17)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await s.store.clearRejected();
                if (ctx.mounted) Navigator.of(ctx).pop();
                _changed();
              },
              child: const Text('Ya avisé, borrar la lista', style: TextStyle(fontSize: 17)),
            ),
            FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cerrar', style: TextStyle(fontSize: 17))),
          ],
        ),
      ),
    );
  }

  Widget _supervisorCard(Map<String, dynamic> sup) {
    final name = sup['name'] as String? ?? 'Supervisor';
    final phone = sup['phone'] as String?;
    final initials = name.trim().isEmpty
        ? '?'
        : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0].toUpperCase()).join();
    return GuardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: gNavy,
                foregroundImage: _photoUrl != null ? NetworkImage(_photoUrl!) : null,
                child: Text(initials, style: const TextStyle(fontSize: 26, color: Colors.white, fontWeight: FontWeight.w900)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Su supervisor', style: TextStyle(fontSize: 17, color: gSoft)),
                    Text(name, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900)),
                    if (phone != null && phone.isNotEmpty) Text(phone, style: const TextStyle(fontSize: 19)),
                  ],
                ),
              ),
            ],
          ),
          if (phone != null && phone.isNotEmpty) ...[
            const SizedBox(height: 12),
            GuardMainButton(label: 'Llamar a mi supervisor', color: gGreen, onTap: () => _call(phone)),
          ],
        ],
      ),
    );
  }
}

/// Consignas del puesto: el guarda las lee y las acepta antes de recibir.
class _OrdersPage extends StatelessWidget {
  const _OrdersPage({required this.postName, required this.orders});
  final String postName;
  final String orders;

  @override
  Widget build(BuildContext context) {
    return GuardPage(
      title: 'Consignas',
      bottom: GuardMainButton(label: 'Entendido, las cumpliré', onTap: () => Navigator.of(context).pop(true)),
      children: [
        GuardTitle('Consignas de $postName', sub: 'Léalas antes de recibir el puesto.'),
        GuardCard(child: Text(orders, style: const TextStyle(fontSize: 21, height: 1.45))),
      ],
    );
  }
}
