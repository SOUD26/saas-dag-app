// Datos del súper administrador: empresas, su suscripción y su licencia DIGESSP.
// La base de datos solo deja escribir esto al súper admin (RLS); aquí solo se lee y se guarda.
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../supabase.dart';
import '../admin/staff_file.dart';

/// Números que pueden llegar como número o como texto (numeric de Postgres).
num? _toNum(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);

/// Empresa en la lista (vista `company_summary`).
class CompanyRow {
  const CompanyRow({
    required this.id,
    required this.name,
    required this.code,
    required this.active,
    this.legalName,
    this.nit,
    this.subStatus,
    this.plan,
    this.fee,
    this.currency = 'GTQ',
    this.sites = 0,
    this.clients = 0,
    this.guards = 0,
    this.supervisors = 0,
    this.licenseNumber,
    this.licenseExpires,
  });

  final String id;
  final String name;
  final String code;
  final bool active;
  final String? legalName;
  final String? nit;
  final String? subStatus;
  final String? plan;
  final double? fee;
  final String currency;
  final int sites;
  final int clients;
  final int guards;
  final int supervisors;
  final String? licenseNumber;
  final DateTime? licenseExpires;

  static int _n(Object? v) => _toNum(v)?.toInt() ?? 0;

  static CompanyRow fromRow(Map<String, dynamic> r) => CompanyRow(
        id: r['id'] as String,
        name: (r['name'] as String?) ?? 'Sin nombre',
        code: (r['code'] as String?) ?? '',
        active: (r['active'] as bool?) ?? true,
        legalName: r['legal_name'] as String?,
        nit: r['nit'] as String?,
        subStatus: r['subscription_status'] as String?,
        plan: r['plan'] as String?,
        fee: _toNum(r['monthly_fee'])?.toDouble(),
        currency: (r['currency'] as String?) ?? 'GTQ',
        sites: _n(r['sites_count']),
        clients: _n(r['clients_count']),
        guards: _n(r['guards_count']),
        supervisors: _n(r['supervisors_count']),
        licenseNumber: r['digessp_license_number'] as String?,
        licenseExpires: parseIsoDate(r['digessp_license_expires_on']),
      );
}

Future<List<CompanyRow>> loadCompanies() async {
  final rows = await supabase.from('company_summary').select().order('name');
  return [for (final r in rows) CompanyRow.fromRow(r)];
}

/// Documentos de empresa vencidos, por vencer o faltantes en todas las empresas.
Future<List<DocAlert>> loadPlatformAlerts({int days = 60}) async {
  final rows = await supabase.rpc('document_alerts', params: {'p_company': null, 'p_days': days});
  if (rows is! List) return const [];
  return [
    for (final r in rows)
      if (r is Map<String, dynamic>) DocAlert.fromRow(r),
  ];
}

const subscriptionStatuses = <(String, String)>[
  ('trial', 'Prueba'),
  ('active', 'Activa'),
  ('suspended', 'Suspendida'),
  ('cancelled', 'Cancelada'),
];

String subscriptionLabel(String? s) {
  for (final x in subscriptionStatuses) {
    if (x.$1 == s) return x.$2;
  }
  return 'Sin suscripción';
}

/// Ficha completa de una empresa.
class CompanyInfo {
  const CompanyInfo({
    required this.id,
    required this.name,
    required this.code,
    required this.active,
    this.legalName,
    this.nit,
    this.legalRep,
    this.phone,
    this.email,
    this.address,
    this.department,
    this.municipality,
    this.subStatus = 'trial',
    this.plan,
    this.fee,
    this.currency = 'GTQ',
    this.billingDay,
    this.startedOn,
    this.trialEndsOn,
    this.notes,
    this.licenseId,
    this.licenseNumber,
    this.licenseIssued,
    this.licenseExpires,
  });

  final String id;
  final String name;
  final String code;
  final bool active;
  final String? legalName;
  final String? nit;
  final String? legalRep;
  final String? phone;
  final String? email;
  final String? address;
  final String? department;
  final String? municipality;
  final String subStatus;
  final String? plan;
  final double? fee;
  final String currency;
  final int? billingDay;
  final DateTime? startedOn;
  final DateTime? trialEndsOn;
  final String? notes;
  final String? licenseId;
  final String? licenseNumber;
  final DateTime? licenseIssued;
  final DateTime? licenseExpires;
}

Future<CompanyInfo> loadCompany(String id) async {
  final c = await supabase.from('companies').select().eq('id', id).single();
  final s = await supabase.from('company_subscriptions').select().eq('company_id', id).maybeSingle();
  final lic = await supabase
      .from('documents')
      .select('id, number, issued_on, expires_on, created_at, document_types!inner(key)')
      .eq('company_id', id)
      .isFilter('profile_id', null)
      .isFilter('client_id', null)
      .eq('document_types.key', 'digessp_license')
      .order('expires_on', ascending: false)
      .limit(1);
  final l = lic.isEmpty ? null : lic.first;
  return CompanyInfo(
    id: c['id'] as String,
    name: (c['name'] as String?) ?? '',
    code: (c['code'] as String?) ?? '',
    active: (c['active'] as bool?) ?? true,
    legalName: c['legal_name'] as String?,
    nit: c['nit'] as String?,
    legalRep: c['legal_rep_name'] as String?,
    phone: c['phone'] as String?,
    email: c['email'] as String?,
    address: c['address'] as String?,
    department: c['department'] as String?,
    municipality: c['municipality'] as String?,
    subStatus: (s?['status'] as String?) ?? 'trial',
    plan: s?['plan'] as String?,
    fee: _toNum(s?['monthly_fee'])?.toDouble(),
    currency: (s?['currency'] as String?) ?? 'GTQ',
    billingDay: _toNum(s?['billing_day'])?.toInt(),
    startedOn: parseIsoDate(s?['started_on']),
    trialEndsOn: parseIsoDate(s?['trial_ends_on']),
    notes: s?['notes'] as String?,
    licenseId: l?['id'] as String?,
    licenseNumber: l?['number'] as String?,
    licenseIssued: parseIsoDate(l?['issued_on']),
    licenseExpires: parseIsoDate(l?['expires_on']),
  );
}

class CompanyError implements Exception {
  const CompanyError(this.message);
  final String message;
  @override
  String toString() => message;
}

String _friendly(PostgrestException e) {
  final m = e.message;
  if (e.code == '23505' && m.contains('nit')) return 'Ya existe una empresa con ese NIT.';
  if (e.code == '23514') {
    if (m.contains('nit')) return 'El NIT no tiene un formato válido.';
    if (m.contains('phone')) return 'El teléfono debe tener al menos 8 dígitos.';
    if (m.contains('email')) return 'El correo no tiene un formato válido.';
    if (m.contains('billing_day')) return 'El día de cobro va de 1 a 28.';
    return 'Hay un dato con formato inválido.';
  }
  if (e.code == '22023' || e.code == '42501') return m;
  return 'No se pudo guardar la empresa.';
}

/// Guarda (o crea, si [id] es null) la empresa, su suscripción y su licencia DIGESSP. Devuelve el id.
Future<String> saveCompany({
  String? id,
  required Map<String, dynamic> company,
  required Map<String, dynamic> subscription,
  String? licenseId,
  String? licenseNumber,
  DateTime? licenseExpires,
  bool licenseRenew = false,
}) async {
  try {
    var cid = id;
    if (cid == null) {
      final row = await supabase.from('companies').insert(company).select('id').single();
      cid = row['id'] as String; // la suscripción y el catálogo de documentos nacen solos
    } else {
      await supabase.from('companies').update(company).eq('id', cid);
    }
    await supabase.from('company_subscriptions').update(subscription).eq('company_id', cid);

    final hasLicense = (licenseNumber != null && licenseNumber.isNotEmpty) || licenseExpires != null;
    if (hasLicense) {
      final values = {
        'number': licenseNumber,
        'expires_on': licenseExpires == null ? null : isoDate(licenseExpires),
      };
      if (licenseId != null && !licenseRenew) {
        await supabase.from('documents').update(values).eq('id', licenseId);
      } else {
        final type = await supabase
            .from('document_types')
            .select('id')
            .eq('company_id', cid)
            .eq('key', 'digessp_license')
            .single();
        await supabase.from('documents').insert({...values, 'company_id': cid, 'type_id': type['id']});
      }
    }
    return cid;
  } on PostgrestException catch (e) {
    throw CompanyError(_friendly(e));
  }
}

/// Activa o suspende la empresa: suspendida = ninguno de sus usuarios puede entrar.
Future<void> setCompanyActive(String id, bool active) async {
  try {
    await supabase.from('companies').update({'active': active}).eq('id', id);
  } on PostgrestException catch (e) {
    throw CompanyError(_friendly(e));
  }
}

/// Revisa el dígito verificador del NIT (módulo 11; "K" vale 10). Solo para AVISAR.
bool nitLooksValid(String raw) {
  final s = raw.toUpperCase().replaceAll(RegExp(r'[^0-9K]'), '');
  if (s.length < 2) return false;
  final body = s.substring(0, s.length - 1);
  final check = s.substring(s.length - 1);
  if (!RegExp(r'^\d+$').hasMatch(body)) return false;
  var sum = 0;
  for (var i = 0; i < body.length; i++) {
    sum += int.parse(body[body.length - 1 - i]) * (i + 2);
  }
  final r = (11 - (sum % 11)) % 11;
  return check == (r == 10 ? 'K' : '$r');
}
