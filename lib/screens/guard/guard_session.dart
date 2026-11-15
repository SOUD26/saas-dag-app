import 'package:flutter/foundation.dart';

import '../../models/profile.dart';
import '../../supabase.dart';
import 'guard_store.dart';

/// Estado del guarda en el teléfono: lo que bajó del servidor, el sitio elegido y la cola de envío.
/// Con señal se actualiza solo; sin señal trabaja con lo guardado.
class GuardSession extends ChangeNotifier {
  GuardSession(this.store, this.profile);

  final GuardStore store;
  final Profile profile;
  bool online = false;
  DateTime? lastRefresh;

  Map<String, dynamic>? get ctx => store.context;

  List<Map<String, dynamic>> get sites => [
        for (final s in (ctx?['sites'] as List<dynamic>? ?? const []))
          Map<String, dynamic>.from(s as Map),
      ];

  Map<String, dynamic>? get site {
    final all = sites;
    final id = store.siteId;
    for (final s in all) {
      if (s['site_id'] == id) return s;
    }
    return all.length == 1 ? all.first : null;
  }

  String? get siteId => site?['site_id'] as String?;
  bool get visitorControl => (site?['visitor_control'] as bool?) ?? false;

  List<Map<String, dynamic>> postsOf(Map<String, dynamic>? s) => [
        for (final p in (s?['posts'] as List<dynamic>? ?? const []))
          Map<String, dynamic>.from(p as Map),
      ];

  List<Map<String, dynamic>> get posts => postsOf(site);

  Map<String, dynamic>? postById(String? id) {
    for (final p in posts) {
      if (p['id'] == id) return p;
    }
    return null;
  }

  /// Puesto en el que está de turno (si recibió y no ha entregado).
  Map<String, dynamic>? get dutyPost => postById(store.dutyPostId);
  bool get onDuty => dutyPost != null;

  /// Su puesto habitual en el sitio (o el primero).
  Map<String, dynamic>? get myPost {
    final p = postById(site?['my_post_id'] as String?);
    if (p != null) return p;
    final all = posts;
    return all.isEmpty ? null : all.first;
  }

  List<Map<String, dynamic>> get supervisors => [
        for (final s in (site?['supervisors'] as List<dynamic>? ?? const []))
          Map<String, dynamic>.from(s as Map),
      ];

  List<Map<String, dynamic>> get docs => [
        for (final d in (ctx?['docs'] as List<dynamic>? ?? const []))
          Map<String, dynamic>.from(d as Map),
      ];

  /// Turno de hoy en este sitio (el que está en curso o el próximo).
  Map<String, dynamic>? get shift {
    final now = DateTime.now();
    Map<String, dynamic>? best;
    for (final raw in (ctx?['shifts'] as List<dynamic>? ?? const [])) {
      final s = Map<String, dynamic>.from(raw as Map);
      if (s['site_id'] != siteId) continue;
      final end = DateTime.tryParse(s['ends_at'] as String? ?? '');
      if (end == null || end.isBefore(now)) continue;
      best ??= s;
    }
    return best;
  }

  int get pending => store.outbox.length;
  int get rejectedCount => store.rejected.length;

  Future<void> chooseSite(String id) async {
    await store.setSiteId(id);
    notifyListeners();
    await refresh();
  }

  /// Baja todo lo necesario para trabajar sin señal y envía lo pendiente.
  Future<void> refresh() async {
    try {
      final c = await supabase.rpc('guard_context');
      await store.setContext(Map<String, dynamic>.from(c as Map));
      online = true;
      lastRefresh = DateTime.now();
      final s = site;
      if (s != null) {
        // La lista del relevo de cada puesto del sitio.
        for (final p in postsOf(s)) {
          final rows = await supabase.rpc('post_checklist', params: {'p_post_id': p['id']});
          await store.setChecklist(p['id'] as String, [
            for (final r in (rows as List<dynamic>)) Map<String, dynamic>.from(r as Map),
          ]);
        }
        _adoptServerDuty(s);
        if (visitorControl) {
          final vc = await supabase.from('visitor_companies').select('id, name, sort_order').eq('active', true).order('sort_order').order('name');
          await store.setVisitorCompanies(vc);
          await refreshInside();
        }
      }
    } catch (_) {
      online = false;
    }
    await sync();
  }

  /// Si el servidor dice que este guarda recibió el puesto y no lo entregó, sigue de turno.
  void _adoptServerDuty(Map<String, dynamic> s) {
    if (store.dutyPostId != null) return;
    final pendingDelivery = store.outbox.any((o) => o.kind == 'handover' && o.params['p_kind'] == 'delivery');
    if (pendingDelivery) return;
    for (final p in postsOf(s)) {
      final last = p['last'] as Map?;
      if (last != null && last['kind'] == 'reception' && last['actor_id'] == profile.id) {
        store.setDuty(p['id'] as String);
        return;
      }
    }
  }

  Future<List<InsideEntry>> refreshInside() async {
    final id = siteId;
    if (id == null) return const [];
    try {
      final rows = await supabase.rpc('site_inside', params: {'p_site_id': id});
      final server = [
        for (final r in (rows as List<dynamic>))
          InsideEntry.fromJson({...Map<String, dynamic>.from(r as Map), 'synced': true}),
      ];
      online = true;
      return await store.mergeInside(id, server);
    } catch (_) {
      return store.inside(id);
    }
  }

  Future<SyncResult> sync() async {
    final r = await store.sync();
    if (r.online != null) online = r.online!;
    notifyListeners();
    return r;
  }

  Future<void> enqueue(GuardOp op) async {
    await store.enqueue(op);
    notifyListeners();
  }
}
