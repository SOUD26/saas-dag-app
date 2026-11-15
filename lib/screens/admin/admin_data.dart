import 'package:supabase_flutter/supabase_flutter.dart' show FunctionException, PostgrestException;

import '../../supabase.dart';
import 'staff_file.dart';

const _gt = Duration(hours: 6); // Guatemala = UTC-6 todo el año

String _2(int n) => n.toString().padLeft(2, '0');

/// Inicio del día de hoy en Guatemala, expresado en UTC (06:00 UTC).
DateTime todayStartUtc() {
  final g = DateTime.now().toUtc().subtract(_gt);
  return DateTime.utc(g.year, g.month, g.day, 6);
}

/// Convierte una fecha/hora escrita en hora de Guatemala a UTC.
DateTime gtToUtc(int y, int m, int d, int h, int min) =>
    DateTime.utc(y, m, d, h, min).add(_gt);

/// Fecha/hora en Guatemala (los campos de año, mes, día, hora son los locales).
DateTime gtLocal(DateTime t) => t.toUtc().subtract(_gt);

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

class AShift {
  const AShift({
    required this.id,
    required this.siteId,
    required this.guardId,
    required this.startsAt,
    required this.endsAt,
    required this.grace,
    required this.cancelled,
    required this.status,
    this.arrivedAt,
    this.lateMinutes,
    this.flags = 0,
    this.notes,
  });
  final String id;
  final String siteId;
  final String guardId;
  final DateTime startsAt;
  final DateTime endsAt;
  final int grace;
  final bool cancelled;
  final String status;
  final DateTime? arrivedAt;
  final int? lateMinutes;
  final int flags;
  final String? notes;
}

/// Persona de la empresa (cualquier rol menos súper admin) para el panel de accesos.
class AStaff {
  const AStaff({
    required this.id,
    required this.name,
    required this.role,
    required this.active,
    this.login,
    this.clientId,
    this.phone,
    this.avatarPath,
  });
  final String id;
  final String name;
  final String role; // company_admin, supervisor, guard, client, resident
  final bool active;
  final String? login; // correo o usuario
  final String? clientId;
  final String? phone;
  final String? avatarPath;
}

/// Permiso del catálogo (tabla `permissions`).
class APerm {
  const APerm({
    required this.key,
    required this.label,
    required this.module,
    required this.description,
    required this.grantableTo,
  });
  final String key;
  final String label;
  final String module;
  final String description;
  final List<String> grantableTo;
}

const roleLabels = <String, String>{
  'company_admin': 'Administrador',
  'supervisor': 'Supervisor',
  'guard': 'Guarda',
  'client': 'Cliente',
  'resident': 'Usuario',
};

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
    this.companies = const [],
    this.isSuper = false,
    this.shifts = const [],
    this.staff = const [],
    this.perms = const [],
    this.userPerms = const {},
    this.myId = '',
    this.avatarUrls = const {},
    this.docAlerts = const [],
  });

  /// Enlaces temporales de las fotos de perfil: personId -> enlace.
  final Map<String, String> avatarUrls;

  /// Documentos vencidos, por vencer (30 días) y faltantes de la empresa.
  final List<DocAlert> docAlerts;

  List<DocAlert> alertsOf(String personId) =>
      docAlerts.where((a) => a.ownerKind == 'staff' && a.ownerId == personId).toList();

  /// Panel de accesos: personas, catálogo de permisos y permisos otorgados.
  final List<AStaff> staff;
  final List<APerm> perms;
  final Map<String, Set<String>> userPerms; // userId -> keys
  final String myId;

  AStaff? staffById(String id) {
    for (final x in staff) {
      if (x.id == id) return x;
    }
    return null;
  }

  /// Turnos de los últimos 30 días y los próximos 30 (con su resultado).
  final List<AShift> shifts;

  List<AShift> shiftsOf(String guardId) =>
      shifts.where((x) => x.guardId == guardId).toList();

  /// Solo para el súper administrador: empresas entre las que puede elegir.
  final List<(String, String)> companies;
  final bool isSuper;
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

Future<AdminData> loadAdminData({String? selectedCompanyId}) async {
  final uid = supabase.auth.currentUser!.id;
  final me = await supabase
      .from('profiles')
      .select('company_id')
      .eq('id', uid)
      .maybeSingle();
  final since = DateTime.now().toUtc().subtract(const Duration(days: 7));

  // El súper administrador no pertenece a una empresa: elige cuál administrar.
  final isSuper = me?['company_id'] == null;
  var companies = <(String, String)>[];
  String? cid = me?['company_id'] as String?;
  if (isSuper) {
    final rows = await supabase.from('companies').select('id, name').order('name');
    companies = [for (final r in rows) (r['id'] as String, r['name'] as String)];
    cid = companies.any((c) => c.$1 == selectedCompanyId)
        ? selectedCompanyId
        : (companies.isNotEmpty ? companies.first.$1 : null);
  }
  bool mine(Map<String, dynamic> r) => !isSuper || r['company_id'] == cid;

  final clientRowsAll = await supabase
      .from('clients')
      .select('id, name, active, company_id')
      .order('name');
  final siteRowsAll = await supabase
      .from('sites')
      .select('id, client_id, name, lat, lng, radius_m, active, company_id')
      .order('name');
  final guardRowsAll = await supabase
      .from('profiles')
      .select('id, full_name, active, company_id')
      .eq('role', 'guard')
      .order('full_name');
  final staffRowsAll = await supabase
      .from('profiles')
      .select('id, full_name, role, active, username, email, company_id, client_id, phone, avatar_path')
      .neq('role', 'super_admin')
      .order('full_name');
  final permRows = await supabase
      .from('permissions')
      .select('key, description, label, module, grantable_to')
      .order('key');
  final upRowsAll =
      await supabase.from('user_permissions').select('user_id, permission, company_id');
  final clientRows = clientRowsAll.where(mine).toList();
  final siteRows = siteRowsAll.where(mine).toList();
  final guardRows = guardRowsAll.where(mine).toList();
  final guardIds = {for (final r in guardRows) r['id'] as String};
  final siteIds = {for (final r in siteRows) r['id'] as String};
  final assignRows =
      await supabase.from('guard_sites').select('guard_id, site_id, active');
  final verifRows = await supabase
      .from('shift_verifications')
      .select(
          'id, guard_id, site_id, kind, flagged, flag_reason, distance_m, face_score, created_at, reviewed_at, review_outcome')
      .gte('created_at', since.toIso8601String())
      .order('created_at', ascending: false)
      .limit(1000);

  final nowUtc = DateTime.now().toUtc();
  final shiftRowsAll = await supabase
      .from('shift_log')
      .select(
          'shift_id, company_id, site_id, guard_id, starts_at, ends_at, grace_minutes, cancelled, notes, arrived_at, late_minutes, flags, status')
      .gte('starts_at', nowUtc.subtract(const Duration(days: 30)).toIso8601String())
      .lte('starts_at', nowUtc.add(const Duration(days: 30)).toIso8601String())
      .order('starts_at', ascending: false)
      .limit(2000);
  final shiftRows = shiftRowsAll.where(mine).toList();

  final assign = <String, Set<String>>{};
  for (final r in assignRows) {
    if (r['active'] == false) continue;
    if (!guardIds.contains(r['guard_id']) || !siteIds.contains(r['site_id'])) continue;
    (assign[r['guard_id'] as String] ??= <String>{}).add(r['site_id'] as String);
  }

  final staffRows = staffRowsAll.where(mine).toList();
  final avatarPaths = <String, String>{
    for (final r in staffRows)
      if (r['avatar_path'] is String) r['id'] as String: r['avatar_path'] as String,
  };
  final signed = await signedAvatarUrls(avatarPaths.values.toList());
  var docAlerts = const <DocAlert>[];
  if (cid != null) {
    try {
      docAlerts = await loadDocAlerts(cid);
    } catch (_) {
      // Sin alertas de documentos no se cae el panel.
    }
  }

  return AdminData(
    companyId: cid,
    myId: uid,
    avatarUrls: {
      for (final e in avatarPaths.entries)
        if (signed[e.value] != null) e.key: signed[e.value]!,
    },
    docAlerts: docAlerts,
    staff: [
      for (final r in staffRows)
        AStaff(
          id: r['id'] as String,
          name: (r['full_name'] as String?) ?? 'Sin nombre',
          role: r['role'] as String,
          active: (r['active'] as bool?) ?? true,
          login: (r['email'] as String?) ?? (r['username'] as String?),
          clientId: r['client_id'] as String?,
          phone: r['phone'] as String?,
          avatarPath: r['avatar_path'] as String?,
        ),
    ],
    perms: [
      for (final r in permRows)
        APerm(
          key: r['key'] as String,
          label: (r['label'] as String?) ?? (r['key'] as String),
          module: (r['module'] as String?) ??
              (r['key'] as String).split('.').first,
          description: (r['description'] as String?) ?? '',
          grantableTo: [
            for (final x in (r['grantable_to'] as List<dynamic>? ?? const []))
              x.toString(),
          ],
        ),
    ],
    userPerms: () {
      final m = <String, Set<String>>{};
      for (final r in upRowsAll.where(mine)) {
        (m[r['user_id'] as String] ??= <String>{}).add(r['permission'] as String);
      }
      return m;
    }(),
    companies: companies,
    isSuper: isSuper,
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
    shifts: [
      for (final r in shiftRows)
        AShift(
          id: r['shift_id'] as String,
          siteId: r['site_id'] as String,
          guardId: r['guard_id'] as String,
          startsAt: DateTime.parse(r['starts_at'] as String),
          endsAt: DateTime.parse(r['ends_at'] as String),
          grace: (r['grace_minutes'] as num?)?.toInt() ?? 10,
          cancelled: (r['cancelled'] as bool?) ?? false,
          status: (r['status'] as String?) ?? 'programado',
          arrivedAt: r['arrived_at'] == null
              ? null
              : DateTime.parse(r['arrived_at'] as String),
          lateMinutes: (r['late_minutes'] as num?)?.toInt(),
          flags: (r['flags'] as num?)?.toInt() ?? 0,
          notes: r['notes'] as String?,
        ),
    ],
    verifs: [
      for (final r in verifRows.where((r) => !isSuper || siteIds.contains(r['site_id'])))
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

/// Error con mensaje listo para mostrar al usuario.
class UserCreateError implements Exception {
  const UserCreateError(this.message);
  final String message;
}

/// Crea un usuario con la función de servidor `admin-users` y devuelve su id.
/// Las reglas de quién puede crear a quién se validan en el servidor (SQL).
Future<String> createUserAccount({
  required String role,
  required String companyId,
  required String fullName,
  String? email,
  String? username,
  String? password,
  String? clientId,
}) async {
  try {
    final res = await supabase.functions.invoke('admin-users', body: {
      'action': 'create_user',
      'role': role,
      'company_id': companyId,
      'full_name': fullName,
      if (email != null) 'email': email,
      if (username != null) 'username': username,
      if (password != null && password.isNotEmpty) 'password': password,
      if (clientId != null) 'client_id': clientId,
    });
    final data = res.data;
    final id = data is Map ? data['id'] as String? : null;
    if (id == null) throw const UserCreateError('El servidor no devolvió el usuario creado.');
    return id;
  } on FunctionException catch (e) {
    final det = e.details;
    final msg = det is Map && det['error'] is String
        ? det['error'] as String
        : 'No se pudo crear el usuario.';
    throw UserCreateError(msg);
  }
}

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

/// Error de turnos con mensaje listo para mostrar.
class ShiftError implements Exception {
  const ShiftError(this.message);
  final String message;
}

ShiftError _shiftError(PostgrestException e) {
  if (e.code == '23P01') {
    return const ShiftError('Ese guarda ya tiene un turno que se cruza con ese horario.');
  }
  if (e.code == '42501') {
    return const ShiftError('No tienes permiso para cambiar turnos de ese sitio.');
  }
  return const ShiftError('No se pudo guardar el turno.');
}

Future<void> insertShifts(List<Map<String, dynamic>> rows) async {
  try {
    await supabase.from('shifts').insert(rows);
  } on PostgrestException catch (e) {
    throw _shiftError(e);
  }
}

Future<void> updateShift(String id, Map<String, dynamic> values) async {
  try {
    await supabase.from('shifts').update({
      ...values,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', id);
  } on PostgrestException catch (e) {
    throw _shiftError(e);
  }
}

Future<void> setUserActive(String userId, bool active) async {
  await supabase.from('profiles').update({'active': active}).eq('id', userId);
}

Future<void> grantPermission(String userId, String key, String companyId) =>
    supabase.from('user_permissions').insert({
      'user_id': userId,
      'permission': key,
      'company_id': companyId,
      'granted_by': supabase.auth.currentUser!.id,
    });

Future<void> revokePermission(String userId, String key) => supabase
    .from('user_permissions')
    .delete()
    .eq('user_id', userId)
    .eq('permission', key);

/// Cambia la contraseña de otra persona con la función de servidor `admin-users`.
Future<void> resetUserPassword(String userId, String password) async {
  try {
    await supabase.functions.invoke('admin-users', body: {
      'action': 'reset_password',
      'user_id': userId,
      'password': password,
    });
  } on FunctionException catch (e) {
    final det = e.details;
    final msg = det is Map && det['error'] is String
        ? det['error'] as String
        : 'No se pudo cambiar la contraseña.';
    throw UserCreateError(msg);
  }
}
