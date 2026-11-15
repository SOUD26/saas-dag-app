// Ficha de personal: datos, documentos con vencimiento, foto de perfil y alertas.
// Las reglas (quién ve y quién edita) viven en la base de datos; aquí solo se lee y se guarda.
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions, PostgrestException;

import '../../supabase.dart';

// ───────────────────────── Fechas (sin hora) ─────────────────────────

String _two(int n) => n.toString().padLeft(2, '0');

/// Hoy, sin hora.
DateTime todayDate() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

/// Días que faltan para [d] (negativo si ya pasó).
int daysFromToday(DateTime d) {
  final t = todayDate();
  return DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(t.year, t.month, t.day)).inDays;
}

/// Formato de la base de datos: aaaa-mm-dd.
String isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

/// Lee "aaaa-mm-dd" (o un timestamp) de la base de datos.
DateTime? parseIsoDate(Object? v) {
  if (v is! String || v.length < 10) return null;
  final y = int.tryParse(v.substring(0, 4));
  final m = int.tryParse(v.substring(5, 7));
  final d = int.tryParse(v.substring(8, 10));
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}

/// dd/mm/aaaa
String fmtDate(DateTime d) => '${_two(d.day)}/${_two(d.month)}/${d.year}';

/// Convierte "dd/mm/aaaa" en fecha. Null si no es una fecha real.
DateTime? parseDmy(String s) {
  final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(s.trim());
  if (m == null) return null;
  final d = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  final y = int.parse(m.group(3)!);
  final dt = DateTime(y, mo, d);
  if (dt.year != y || dt.month != mo || dt.day != d) return null;
  return dt;
}

// ───────────────────────── Validaciones ─────────────────────────

String onlyDigits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

/// Revisa el dígito verificador del DPI (CUI). RENAP no publica el algoritmo; este es el que usa
/// la comunidad (módulo 11). Por eso solo se usa para AVISAR, nunca para bloquear.
bool dpiLooksValid(String digits) {
  if (!RegExp(r'^\d{13}$').hasMatch(digits)) return false;
  final dept = int.parse(digits.substring(9, 11));
  final muni = int.parse(digits.substring(11, 13));
  if (dept < 1 || dept > 22 || muni < 1) return false;
  var sum = 0;
  for (var i = 0; i < 8; i++) {
    sum += int.parse(digits[i]) * (i + 2);
  }
  return sum % 11 == int.parse(digits[8]);
}

/// "1234567890101" -> "1234 56789 0101"
String fmtDpi(String? digits) {
  final s = onlyDigits(digits ?? '');
  if (s.length != 13) return s;
  return '${s.substring(0, 4)} ${s.substring(4, 9)} ${s.substring(9)}';
}

// ───────────────────────── Documentos ─────────────────────────

/// Claves de los tipos de documento de personal (tabla document_types.key).
class DocKey {
  static const dpi = 'dpi';
  static const weapon = 'weapon_license';
  static const vehicle = 'driver_license';
  static const moto = 'motorcycle_license';
  static const digessp = 'digessp_credential';
  static const criminal = 'criminal_record';
  static const police = 'police_record';
}

class StaffDoc {
  const StaffDoc(this.key, {this.id, this.number, this.issuedOn, this.expiresOn});
  final String key;
  final String? id;
  final String? number;
  final DateTime? issuedOn;
  final DateTime? expiresOn;
}

/// Ficha completa de una persona, tal como está guardada.
class StaffFile {
  const StaffFile({
    required this.role,
    required this.fullName,
    this.login,
    this.phone,
    this.avatarPath,
    this.hasRecord = false,
    this.firstNames = '',
    this.lastNames = '',
    this.employeeCode,
    this.dpi,
    this.birthDate,
    this.address,
    this.department,
    this.municipality,
    this.emergencyName,
    this.emergencyPhone,
    this.emergencyRelation,
    this.hireDate,
    this.carriesWeapon = false,
    this.drivesMotorcycle = false,
    this.drivesVehicle = false,
    this.docs = const {},
  });

  final String role;
  final String fullName;
  final String? login;
  final String? phone;
  final String? avatarPath;
  final bool hasRecord;
  final String firstNames;
  final String lastNames;
  final String? employeeCode;
  final String? dpi;
  final DateTime? birthDate;
  final String? address;
  final String? department;
  final String? municipality;
  final String? emergencyName;
  final String? emergencyPhone;
  final String? emergencyRelation;
  final DateTime? hireDate;
  final bool carriesWeapon;
  final bool drivesMotorcycle;
  final bool drivesVehicle;

  /// Documento vigente de cada tipo (el de vencimiento más lejano).
  final Map<String, StaffDoc> docs;
}

/// Parte un nombre completo en nombres y apellidos (solo para prellenar).
(String, String) splitFullName(String full) {
  final parts = full.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
  if (parts.length <= 1) return (full.trim(), '');
  final cut = parts.length >= 4 ? 2 : 1;
  return (parts.take(cut).join(' '), parts.skip(cut).join(' '));
}

bool _newer(Map<String, dynamic> a, Map<String, dynamic> b) {
  final ea = (a['expires_on'] as String?) ?? '9999-12-31';
  final eb = (b['expires_on'] as String?) ?? '9999-12-31';
  final c = ea.compareTo(eb);
  if (c != 0) return c > 0;
  return ((a['created_at'] as String?) ?? '').compareTo((b['created_at'] as String?) ?? '') > 0;
}

Future<StaffFile> loadStaffFile(String profileId) async {
  final p = await supabase
      .from('profiles')
      .select('role, full_name, phone, avatar_path, email, username')
      .eq('id', profileId)
      .single();
  final r = await supabase.from('staff_records').select().eq('profile_id', profileId).maybeSingle();
  final rows = await supabase
      .from('documents')
      .select('id, number, issued_on, expires_on, created_at, document_types(key)')
      .eq('profile_id', profileId);

  final best = <String, Map<String, dynamic>>{};
  for (final row in rows) {
    final t = row['document_types'];
    final key = t is Map ? t['key'] as String? : null;
    if (key == null) continue;
    final cur = best[key];
    if (cur == null || _newer(row, cur)) best[key] = row;
  }

  final fullName = (p['full_name'] as String?) ?? '';
  final split = splitFullName(fullName);
  return StaffFile(
    role: p['role'] as String,
    fullName: fullName,
    login: (p['email'] as String?) ?? (p['username'] as String?),
    phone: p['phone'] as String?,
    avatarPath: p['avatar_path'] as String?,
    hasRecord: r != null,
    firstNames: (r?['first_names'] as String?) ?? split.$1,
    lastNames: (r?['last_names'] as String?) ?? split.$2,
    employeeCode: r?['employee_code'] as String?,
    dpi: r?['dpi'] as String?,
    birthDate: parseIsoDate(r?['birth_date']),
    address: r?['address'] as String?,
    department: r?['department'] as String?,
    municipality: r?['municipality'] as String?,
    emergencyName: r?['emergency_contact_name'] as String?,
    emergencyPhone: r?['emergency_contact_phone'] as String?,
    emergencyRelation: r?['emergency_contact_relation'] as String?,
    hireDate: parseIsoDate(r?['hire_date']),
    carriesWeapon: (r?['carries_weapon'] as bool?) ?? false,
    drivesMotorcycle: (r?['drives_motorcycle'] as bool?) ?? false,
    drivesVehicle: (r?['drives_vehicle'] as bool?) ?? false,
    docs: {
      for (final e in best.entries)
        e.key: StaffDoc(
          e.key,
          id: e.value['id'] as String?,
          number: e.value['number'] as String?,
          issuedOn: parseIsoDate(e.value['issued_on']),
          expiresOn: parseIsoDate(e.value['expires_on']),
        ),
    },
  );
}

/// Error con mensaje listo para mostrar.
class StaffFileError implements Exception {
  const StaffFileError(this.message);
  final String message;
  @override
  String toString() => message;
}

String friendlyDbError(PostgrestException e) {
  final m = e.message;
  if (e.code == '23505') {
    if (m.contains('dpi')) return 'Ese DPI ya está registrado en la empresa.';
    if (m.contains('code')) return 'Ese código de empleado ya existe en la empresa.';
    return 'Ese dato ya existe en la empresa.';
  }
  if (e.code == '23514') {
    if (m.contains('dpi')) return 'El DPI debe tener 13 dígitos.';
    if (m.contains('phone')) return 'Revisa los teléfonos: mínimo 8 dígitos.';
    if (m.contains('dates')) return 'Revisa las fechas: el vencimiento no puede ser antes de la emisión.';
    return 'Hay un dato con formato inválido.';
  }
  if (e.code == '22007' || e.code == '22008') return 'Hay una fecha inválida.';
  if (e.code == '22023' || e.code == '42501') return m; // mensajes en español del servidor
  return 'No se pudo guardar la ficha.';
}

/// Guarda teléfono + ficha + documentos en un solo paso (todo o nada).
Future<void> saveStaffFile(
  String profileId, {
  required String? phone,
  Map<String, dynamic>? record,
  List<Map<String, dynamic>>? documents,
}) async {
  try {
    await supabase.rpc('save_staff_file', params: {
      'p_profile': profileId,
      'p_phone': phone,
      'p_record': record,
      'p_documents': documents,
    });
  } on PostgrestException catch (e) {
    throw StaffFileError(friendlyDbError(e));
  }
}

/// Cambia el nombre de alguien sin ficha de personal (cliente o usuario).
Future<void> saveFullName(String profileId, String name) async {
  try {
    await supabase.from('profiles').update({'full_name': name}).eq('id', profileId);
  } on PostgrestException catch (e) {
    throw StaffFileError(friendlyDbError(e));
  }
}

/// Revisa DPI y código de empleado repetidos antes de crear la cuenta. Devuelve el problema o null.
Future<String?> staffPrecheck(
  String companyId, {
  required String dpi,
  String? employeeCode,
  String? profileId,
}) async {
  final r = await supabase.rpc('staff_precheck', params: {
    'p_company': companyId,
    'p_dpi': dpi,
    'p_employee_code': employeeCode,
    'p_profile': profileId,
  });
  return r is String && r.isNotEmpty ? r : null;
}

// ───────────────────────── Foto de perfil ─────────────────────────

String _ext(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.png')) return 'png';
  if (n.endsWith('.webp')) return 'webp';
  return 'jpg';
}

/// Sube la foto (bucket privado `avatars`) y la deja como foto de perfil.
Future<void> uploadAvatar(String profileId, Uint8List bytes, String fileName, {String? oldPath}) async {
  final ext = _ext(fileName);
  final path = '$profileId/${DateTime.now().millisecondsSinceEpoch}.$ext';
  try {
    await supabase.storage.from('avatars').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            contentType: ext == 'png' ? 'image/png' : (ext == 'webp' ? 'image/webp' : 'image/jpeg'),
          ),
        );
    await supabase.from('profiles').update({'avatar_path': path}).eq('id', profileId);
  } catch (_) {
    throw const StaffFileError('No se pudo subir la foto (máximo 2 MB, JPG o PNG).');
  }
  if (oldPath != null && oldPath != path) {
    try {
      await supabase.storage.from('avatars').remove([oldPath]);
    } catch (_) {
      // La foto vieja se queda: no es grave.
    }
  }
}

/// Enlace temporal (1 hora) para ver una foto privada.
Future<String?> signedAvatarUrl(String? path) async {
  if (path == null) return null;
  try {
    return await supabase.storage.from('avatars').createSignedUrl(path, 3600);
  } catch (_) {
    return null;
  }
}

/// Enlaces temporales de varias fotos en una sola llamada: ruta -> enlace.
Future<Map<String, String>> signedAvatarUrls(List<String> paths) async {
  if (paths.isEmpty) return const {};
  try {
    final r = await supabase.storage.from('avatars').createSignedUrls(paths, 3600);
    return {for (final s in r) s.path: s.signedUrl};
  } catch (_) {
    return const {};
  }
}

// ───────────────────────── Alertas de documentos ─────────────────────────

class DocStatus {
  static const expired = 'expired';
  static const expiring = 'expiring';
  static const missing = 'missing';
}

class DocAlert {
  const DocAlert({
    required this.ownerKind,
    required this.ownerId,
    required this.ownerName,
    required this.typeName,
    required this.status,
    this.ownerRole,
    this.typeKey,
    this.documentId,
    this.expiresOn,
  });

  final String ownerKind; // staff, company, client
  final String ownerId;
  final String ownerName;
  final String? ownerRole;
  final String? typeKey;
  final String typeName;
  final String? documentId;
  final DateTime? expiresOn;
  final String status; // expired, expiring, missing

  bool get urgent => status != DocStatus.expiring;

  /// "Vencido hace 3 días", "Vence en 12 días", "Falta".
  String get when {
    if (status == DocStatus.missing || expiresOn == null) return 'Falta';
    final n = daysFromToday(expiresOn!);
    if (n < 0) return 'Vencido hace ${-n} ${-n == 1 ? 'día' : 'días'}';
    if (n == 0) return 'Vence hoy';
    return 'Vence en $n ${n == 1 ? 'día' : 'días'} (${fmtDate(expiresOn!)})';
  }

  static DocAlert fromRow(Map<String, dynamic> r) => DocAlert(
        ownerKind: (r['owner_kind'] as String?) ?? 'staff',
        ownerId: r['owner_id'] as String,
        ownerName: (r['owner_name'] as String?) ?? 'Sin nombre',
        ownerRole: r['owner_role'] as String?,
        typeKey: r['type_key'] as String?,
        typeName: (r['type_name'] as String?) ?? 'Documento',
        documentId: r['document_id'] as String?,
        expiresOn: parseIsoDate(r['expires_on']),
        status: (r['status'] as String?) ?? DocStatus.missing,
      );
}

/// Vencidos, por vencer (próximos [days] días) y faltantes de la empresa.
Future<List<DocAlert>> loadDocAlerts(String companyId, {int days = 30}) async {
  final rows = await supabase.rpc('document_alerts', params: {'p_company': companyId, 'p_days': days});
  if (rows is! List) return const [];
  return [
    for (final r in rows)
      if (r is Map<String, dynamic>) DocAlert.fromRow(r),
  ];
}
