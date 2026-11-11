import '../../supabase.dart';

const _gt = Duration(hours: 6); // Guatemala = UTC-6 todo el año

String _2(int n) => n.toString().padLeft(2, '0');

/// Inicio del día de hoy en Guatemala, expresado en UTC (06:00 UTC).
DateTime todayStartUtc() {
  final g = DateTime.now().toUtc().subtract(_gt);
  return DateTime.utc(g.year, g.month, g.day, 6);
}

String fmtTime(DateTime t) {
  final l = t.toUtc().subtract(_gt);
  return '${_2(l.hour)}:${_2(l.minute)}';
}

String fmtDay(DateTime t) {
  final l = t.toUtc().subtract(_gt);
  return '${_2(l.day)}/${_2(l.month)}';
}

/// "Hoy 14:32" o "09/11 14:32".
String fmtWhen(DateTime t) {
  final today = !t.toUtc().isBefore(todayStartUtc());
  return '${today ? 'Hoy' : fmtDay(t)} ${fmtTime(t)}';
}

class Outcome {
  static const justified = 'justified';
  static const falseAlarm = 'false_alarm';
  static const action = 'action_required';
  static const all = [justified, falseAlarm, action];

  static String label(String? o) {
    switch (o) {
      case justified:
        return 'Justificada';
      case falseAlarm:
        return 'Falsa alarma';
      case action:
        return 'Requiere acción';
      default:
        return 'Pendiente';
    }
  }
}

class AClient {
  const AClient(this.id, this.name, this.active);
  final String id;
  final String name;
  final bool active;
}

class ASite {
  const ASite({
    required this.id,
    required this.name,
    required this.radius,
    required this.active,
    this.clientId,
    this.lat,
    this.lng,
  });
  final String id;
  final String name;
  final String? clientId;
  final double? lat;
  final double? lng;
  final int radius;
  final bool active;
  bool get hasCoords => lat != null && lng != null;
}

class AGuard {
  const AGuard(this.id, this.name, this.active);
  final String id;
  final String name;
  final bool active;
}

class AVerif {
  const AVerif({
    required this.id,
    required this.kind,
    required this.flagged,
    required this.createdAt,
    this.guardId,
    this.siteId,
    this.reason,
    this.distance,
    this.score,
    this.reviewedAt,
    this.outcome,
  });
  final String id;
  final String? guardId;
  final String? siteId;
  final String kind;
  final bool flagged;
  final String? reason;
  final double? distance;
  final double? score;
  final DateTime createdAt;
  final DateTime? reviewedAt;
  final String? outcome;
  bool get reviewed => reviewedAt != null;
  bool get pending => flagged && !reviewed;
}

class AdminData {
  AdminData({
    required this.companyId,
    required this.clients,
    required this.sites,
    required this.guards,
    required this.assign,
    required this.verifs,
  });

  final String? companyId;
  final List<AClient> clients;
  final List<ASite> sites;
  final List<AGuard> guards;
  final Map<String, Set<String>> assign; // guardId -> siteIds
  final List<AVerif> verifs; // últimos 7 días, más recientes primero

  List<AVerif> get flags => verifs.where((v) => v.flagged).toList();
  List<AVerif> get pending => verifs.where((v) => v.pending).toList();

  /// Guardas con 2 o más banderas en los últimos 7 días.
  Set<String> get repeatGuards {
    final c = <String, int>{};
    for (final v in verifs) {
      if (v.flagged && v.guardId != null) {
        c[v.guardId!] = (c[v.guardId!] ?? 0) + 1;
      }
    }
    return {
      for (final e in c.entries)
        if (e.value >= 2) e.key,
    };
  }

  int flagCount(String guardId) =>
      verifs.where((v) => v.flagged && v.guardId == guardId).length;

  Set<String> get verifiedTodayGuards {
    final t = todayStartUtc();
    return {
      for (final v in verifs)
        if (v.guardId != null && !v.createdAt.isBefore(t)) v.guardId!,
    };
  }

  List<ASite> get sitesWithoutCheckToday {
    final t = todayStartUtc();
    final covered = {
      for (final v in verifs)
        if (v.siteId != null && !v.createdAt.isBefore(t)) v.siteId!,
    };
    return sites.where((s) => s.active && !covered.contains(s.id)).toList();
  }

  int pendingAt(String siteId) =>
      verifs.where((v) => v.pending && v.siteId == siteId).length;

  ASite? site(String? id) {
    for (final s in sites) {
      if (s.id == id) return s;
    }
    return null;
  }

  AGuard? guard(String? id) {
    for (final g in guards) {
      if (g.id == id) return g;
    }
    return null;
  }

  String siteName(String? id) => site(id)?.name ?? 'Sitio sin nombre';
  String guardName(String? id) => guard(id)?.name ?? 'Persona no identificada';

  String clientName(String? id) {
    for (final c in clients) {
      if (c.id == id) return c.name;
    }
    return 'Sin cliente';
  }

  List<AGuard> guardsAt(String siteId) => guards
      .where((g) => (assign[g.id] ?? const <String>{}).contains(siteId))
      .toList();
}

double? _num(dynamic v) => v == null ? null : (v as num).toDouble();

Future<AdminData> loadAdminData() async {
  final uid = supabase.auth.currentUser!.id;
  final me = await supabase
      .from('profiles')
      .select('company_id')
      .eq('id', uid)
      .maybeSingle();
  final since = DateTime.now().toUtc().subtract(const Duration(days: 7));

  final clientRows =
      await supabase.from('clients').select('id, name, active').order('name');
  final siteRows = await supabase
      .from('sites')
      .select('id, client_id, name, lat, lng, radius_m, active')
      .order('name');
  final guardRows = await supabase
      .from('profiles')
      .select('id, full_name, active')
      .eq('role', 'guard')
      .order('full_name');
  final assignRows =
      await supabase.from('guard_sites').select('guard_id, site_id, active');
  final verifRows = await supabase
      .from('shift_verifications')
      .select(
          'id, guard_id, site_id, kind, flagged, flag_reason, distance_m, face_score, created_at, reviewed_at, review_outcome')
      .gte('created_at', since.toIso8601String())
      .order('created_at', ascending: false)
      .limit(1000);

  final assign = <String, Set<String>>{};
  for (final r in assignRows) {
    if (r['active'] == false) continue;
    (assign[r['guard_id'] as String] ??= <String>{}).add(r['site_id'] as String);
  }

  return AdminData(
    companyId: me?['company_id'] as String?,
    clients: [
      for (final r in clientRows)
        AClient(r['id'] as String, r['name'] as String, (r['active'] as bool?) ?? true),
    ],
    sites: [
      for (final r in siteRows)
        ASite(
          id: r['id'] as String,
          name: r['name'] as String,
          clientId: r['client_id'] as String?,
          lat: _num(r['lat']),
          lng: _num(r['lng']),
          radius: (r['radius_m'] as num?)?.toInt() ?? 0,
          active: (r['active'] as bool?) ?? true,
        ),
    ],
    guards: [
      for (final r in guardRows)
        AGuard(
          r['id'] as String,
          (r['full_name'] as String?) ?? 'Sin nombre',
          (r['active'] as bool?) ?? true,
        ),
    ],
    assign: assign,
    verifs: [
      for (final r in verifRows)
        AVerif(
          id: r['id'] as String,
          guardId: r['guard_id'] as String?,
          siteId: r['site_id'] as String?,
          kind: (r['kind'] as String?) ?? '',
          flagged: (r['flagged'] as bool?) ?? false,
          reason: r['flag_reason'] as String?,
          distance: _num(r['distance_m']),
          score: _num(r['face_score']),
          createdAt: DateTime.parse(r['created_at'] as String),
          reviewedAt: r['reviewed_at'] == null
              ? null
              : DateTime.parse(r['reviewed_at'] as String),
          outcome: r['review_outcome'] as String?,
        ),
    ],
  );
}

Future<void> reviewVerif(String id, String outcome) =>
    supabase.rpc('review_verification', params: {'p_id': id, 'p_outcome': outcome});

Future<void> reopenVerif(String id) =>
    supabase.rpc('reopen_verification', params: {'p_id': id});

Future<void> createClient(String companyId, String name) =>
    supabase.from('clients').insert({'company_id': companyId, 'name': name});

Future<void> createSite({
  required String companyId,
  required String name,
  required double lat,
  required double lng,
  required int radius,
  String? clientId,
}) =>
    supabase.from('sites').insert({
      'company_id': companyId,
      'client_id': clientId,
      'name': name,
      'lat': lat,
      'lng': lng,
      'radius_m': radius,
    });
