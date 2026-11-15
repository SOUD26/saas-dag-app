import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions, PostgrestException, StorageException;

import '../../supabase.dart';
import 'files.dart';

/// Registro que el guarda hizo y que aún no llega al servidor (o que el servidor rechazó).
class GuardOp {
  GuardOp({
    required this.id,
    required this.kind,
    required this.params,
    required this.label,
    required this.at,
    this.error,
  });

  final String id; // mismo id que viaja al servidor: si llega dos veces, no se duplica
  final String kind; // verification | handover | entry | exit | log | photo
  final Map<String, dynamic> params; // parámetros de la función del servidor
  final String label; // para mostrar: "Ingreso P-123ABC"
  final DateTime at;
  String? error;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'params': params,
        'label': label,
        'at': at.toIso8601String(),
        'error': error,
      };

  static GuardOp fromJson(Map<String, dynamic> j) => GuardOp(
        id: j['id'] as String,
        kind: j['kind'] as String,
        params: Map<String, dynamic>.from(j['params'] as Map),
        label: (j['label'] as String?) ?? '',
        at: DateTime.parse(j['at'] as String),
        error: j['error'] as String?,
      );
}

/// Alguien que está dentro del sitio (copia del servidor más lo que aún no subió).
class InsideEntry {
  InsideEntry({
    required this.id,
    required this.kind,
    required this.enteredAt,
    this.plate,
    this.personName,
    this.docKind,
    this.docLast4,
    this.companyName,
    this.destination,
    this.synced = true,
  });

  final String id;
  final String kind; // vehicle | motorcycle | pedestrian
  final DateTime enteredAt;
  final String? plate;
  final String? personName;
  final String? docKind;
  final String? docLast4;
  final String? companyName;
  final String? destination;
  final bool synced;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'entered_at': enteredAt.toIso8601String(),
        'plate': plate,
        'person_name': personName,
        'doc_kind': docKind,
        'doc_last4': docLast4,
        'company_name': companyName,
        'destination': destination,
        'synced': synced,
      };

  static InsideEntry fromJson(Map<String, dynamic> j) => InsideEntry(
        id: j['id'] as String,
        kind: (j['kind'] as String?) ?? 'vehicle',
        enteredAt: DateTime.parse(j['entered_at'] as String).toLocal(),
        plate: j['plate'] as String?,
        personName: j['person_name'] as String?,
        docKind: j['doc_kind'] as String?,
        docLast4: j['doc_last4'] as String?,
        companyName: j['company_name'] as String?,
        destination: j['destination'] as String?,
        synced: (j['synced'] as bool?) ?? true,
      );
}

class SyncResult {
  const SyncResult({required this.sent, required this.pending, required this.online, this.rejected = 0});
  final int sent;
  final int pending;
  final bool online;
  final int rejected;
}

/// Lo que el teléfono guarda para que el guarda trabaje sin señal. Todo va por usuario: si en el
/// teléfono del sitio entra otro guarda, no ve ni envía lo del anterior.
class GuardStore {
  GuardStore._(this._p, this.uid);

  final SharedPreferences _p;
  final String uid;
  bool _syncing = false;
  final Map<String, dynamic> results = {}; // respuesta del servidor por id de registro

  static Future<GuardStore> open(String uid) async => GuardStore._(await SharedPreferences.getInstance(), uid);

  String _k(String name) => 'guard1:$uid:$name';

  Map<String, dynamic>? _map(String key) {
    final s = _p.getString(_k(key));
    if (s == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> _list(String key) {
    final s = _p.getString(_k(key));
    if (s == null) return [];
    try {
      return [for (final x in (jsonDecode(s) as List)) Map<String, dynamic>.from(x as Map)];
    } catch (_) {
      return [];
    }
  }

  Future<void> _put(String key, Object value) => _p.setString(_k(key), jsonEncode(value));

  // ───── Contexto (sitios, puestos, supervisores, turnos) ─────
  Map<String, dynamic>? get context => _map('ctx');
  Future<void> setContext(Map<String, dynamic> c) => _put('ctx', c);

  // ───── Lista del relevo por puesto (a ciegas) ─────
  List<Map<String, dynamic>> checklist(String postId) => _list('chk:$postId');
  Future<void> setChecklist(String postId, List<Map<String, dynamic>> items) => _put('chk:$postId', items);

  // ───── Empresas que visitan ─────
  List<Map<String, dynamic>> get visitorCompanies => _list('vc');
  Future<void> setVisitorCompanies(List<Map<String, dynamic>> l) => _put('vc', l);

  // ───── Sitio y turno ─────
  String? get siteId => _p.getString(_k('site'));
  Future<void> setSiteId(String? id) async {
    if (id == null) {
      await _p.remove(_k('site'));
    } else {
      await _p.setString(_k('site'), id);
    }
  }

  /// Puesto que este guarda recibió y aún no entrega.
  String? get dutyPostId => _map('duty')?['post_id'] as String?;
  DateTime? get dutySince {
    final s = _map('duty')?['since'] as String?;
    return s == null ? null : DateTime.tryParse(s)?.toLocal();
  }

  Future<void> setDuty(String? postId) async {
    if (postId == null) {
      await _p.remove(_k('duty'));
    } else {
      await _put('duty', {'post_id': postId, 'since': DateTime.now().toIso8601String()});
    }
  }

  /// Si ya inició turno (verificación con GPS) en este sitio en las últimas 2 horas, no se repite.
  bool recentlyVerified(String siteId) {
    final v = _map('ver');
    if (v == null || v['site_id'] != siteId) return false;
    final at = DateTime.tryParse(v['at'] as String? ?? '');
    return at != null && DateTime.now().difference(at).inMinutes < 120;
  }

  Future<void> markVerified(String siteId) =>
      _put('ver', {'site_id': siteId, 'at': DateTime.now().toIso8601String()});

  // ───── Quién está dentro ─────
  List<InsideEntry> inside(String siteId) => [for (final j in _list('inside:$siteId')) InsideEntry.fromJson(j)];
  Future<void> setInside(String siteId, List<InsideEntry> l) => _put('inside:$siteId', [for (final e in l) e.toJson()]);

  Future<void> addInside(String siteId, InsideEntry e) async {
    final l = inside(siteId)..removeWhere((x) => x.id == e.id);
    l.insert(0, e);
    await setInside(siteId, l);
  }

  Future<void> removeInside(String siteId, String entryId) async {
    final l = inside(siteId)..removeWhere((x) => x.id == entryId);
    await setInside(siteId, l);
  }

  /// Mezcla lo que dice el servidor con lo que aún no sube.
  Future<List<InsideEntry>> mergeInside(String siteId, List<InsideEntry> server) async {
    final pendingExits = {
      for (final op in outbox)
        if (op.kind == 'exit') op.params['p_id'] as String,
    };
    final serverIds = {for (final e in server) e.id};
    final localOnly = inside(siteId).where((e) => !e.synced && !serverIds.contains(e.id)).toList();
    final merged = [...localOnly, ...server].where((e) => !pendingExits.contains(e.id)).toList()
      ..sort((a, b) => b.enteredAt.compareTo(a.enteredAt));
    await setInside(siteId, merged);
    return merged;
  }

  // ───── Cola de envío ─────
  List<GuardOp> get outbox => [for (final j in _list('outbox')) GuardOp.fromJson(j)];
  Future<void> _saveOutbox(List<GuardOp> l) => _put('outbox', [for (final o in l) o.toJson()]);
  List<GuardOp> get rejected => [for (final j in _list('rejected')) GuardOp.fromJson(j)];
  Future<void> clearRejected() => _p.remove(_k('rejected'));

  Future<void> enqueue(GuardOp op) async {
    final l = outbox..add(op);
    await _saveOutbox(l);
  }

  /// Envía en orden lo pendiente. Si no hay señal, se detiene y lo intenta después.
  /// Lo que el servidor rechaza (por ejemplo, el guarda ya no está asignado) se aparta y se muestra.
  Future<SyncResult> sync() async {
    if (_syncing) return SyncResult(sent: 0, pending: outbox.length, online: true);
    _syncing = true;
    var sent = 0;
    var bad = 0;
    try {
      while (true) {
        final q = outbox;
        if (q.isEmpty) return SyncResult(sent: sent, pending: 0, online: true, rejected: bad);
        final op = q.first;
        try {
          results[op.id] = await _send(op);
          q.removeAt(0);
          await _saveOutbox(q);
          sent++;
          if (op.kind == 'entry') await _markSynced(op);
        } on PostgrestException catch (e) {
          if (_isRejection(e)) {
            await _reject(q, op, e.message);
            bad++;
            continue;
          }
          return SyncResult(sent: sent, pending: q.length, online: false, rejected: bad);
        } on StorageException catch (e) {
          if (const {'400', '401', '403', '413', '415'}.contains(e.statusCode)) {
            await _reject(q, op, 'La foto no se pudo subir: ${e.message}');
            bad++;
            continue;
          }
          return SyncResult(sent: sent, pending: q.length, online: false, rejected: bad);
        } on _PhotoGone {
          await _reject(q, op, 'La foto ya no estaba en el teléfono.');
          bad++;
          continue;
        } catch (_) {
          return SyncResult(sent: sent, pending: q.length, online: false, rejected: bad);
        }
      }
    } finally {
      _syncing = false;
    }
  }

  Future<void> _reject(List<GuardOp> q, GuardOp op, String why) async {
    q.removeAt(0);
    await _saveOutbox(q);
    op.error = why;
    await _put('rejected', [...rejected.map((r) => r.toJson()), op.toJson()]);
    final local = op.params['local_path'];
    if (op.kind == 'photo' && local is String) await deletePhoto(local);
  }

  bool _isRejection(PostgrestException e) =>
      const {'22023', '42501', 'P0001', '23505', '23503', '23514', '22P02'}.contains(e.code);

  Future<void> _markSynced(GuardOp op) async {
    final site = op.params['p_site_id'] as String?;
    if (site == null) return;
    final l = inside(site);
    final i = l.indexWhere((e) => e.id == op.id);
    if (i < 0) return;
    final e = l[i];
    l[i] = InsideEntry(
      id: e.id,
      kind: e.kind,
      enteredAt: e.enteredAt,
      plate: e.plate,
      personName: e.personName,
      docKind: e.docKind,
      docLast4: e.docLast4,
      companyName: e.companyName,
      destination: e.destination,
    );
    await setInside(site, l);
  }

  Future<dynamic> _send(GuardOp op) {
    switch (op.kind) {
      case 'verification':
        return supabase.rpc('record_verification', params: op.params);
      case 'handover':
        return supabase.rpc('record_handover', params: op.params);
      case 'entry':
        return supabase.rpc('register_entry', params: op.params);
      case 'exit':
        return supabase.rpc('register_exit', params: op.params);
      case 'log':
        return supabase.rpc('add_log_entry', params: op.params);
      case 'photo':
        return _sendPhoto(op);
    }
    throw StateError('registro desconocido: ${op.kind}');
  }

  /// Sube la foto del documento y anota su ruta en el ingreso. Después la borra del teléfono.
  Future<bool> _sendPhoto(GuardOp op) async {
    final local = op.params['local_path'] as String;
    final path = op.params['path'] as String;
    final bytes = await readPhoto(local);
    if (bytes == null) throw const _PhotoGone();
    try {
      await supabase.storage.from('visitor_docs').uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );
    } on StorageException catch (e) {
      // Ya estaba arriba (se cortó la señal justo después de subirla): sigue normal.
      final duplicate = e.statusCode == '409' || e.message.toLowerCase().contains('exists');
      if (!duplicate) rethrow;
    }
    await supabase.rpc('set_entry_photo', params: {'p_entry_id': op.params['entry_id'], 'p_path': path});
    await deletePhoto(local);
    return true;
  }
}

class _PhotoGone implements Exception {
  const _PhotoGone();
}
