import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../supabase.dart';
import '../../theme.dart';
import '../admin/staff_file.dart' show isoDate, parseIsoDate;

// ───────────────────────── Niveles de alerta ─────────────────────────
// red = actuar ya · orange = revisar hoy · yellow = revisar cuando se pueda.

const kOrange = Color(0xFFE65100);
const kYellow = Color(0xFFB58900);

Color sevColor(String? s) {
  switch (s) {
    case 'red':
      return AppColors.danger;
    case 'orange':
      return kOrange;
    case 'yellow':
      return kYellow;
  }
  return AppColors.muted;
}

String sevLabel(String? s) {
  switch (s) {
    case 'red':
      return 'Roja';
    case 'orange':
      return 'Naranja';
    case 'yellow':
      return 'Amarilla';
  }
  return 'Sin nivel';
}

String sevHint(String? s) {
  switch (s) {
    case 'red':
      return 'Actuar ya';
    case 'orange':
      return 'Revisar hoy';
    case 'yellow':
      return 'Revisar cuando se pueda';
  }
  return '';
}

int sevRank(String? s) => s == 'red' ? 3 : (s == 'orange' ? 2 : (s == 'yellow' ? 1 : 0));

// ───────────────────────── Estados del sitio ─────────────────────────

String siteStatusLabel(String s) {
  switch (s) {
    case 'draft':
      return 'Borrador';
    case 'pending':
      return 'Por aprobar';
    case 'returned':
      return 'Devuelto';
  }
  return 'Aprobado';
}

Color siteStatusColor(String s) {
  switch (s) {
    case 'draft':
      return AppColors.muted;
    case 'pending':
      return kOrange;
    case 'returned':
      return AppColors.danger;
  }
  return const Color(0xFF2E7D32);
}

String implStatusLabel(String s) {
  switch (s) {
    case 'damaged':
      return 'Mal estado';
    case 'missing':
      return 'Falta';
  }
  return 'Bien';
}

// ───────────────────────── Catálogo de implementos ─────────────────────────

const implCategories = <String, String>{
  'arma': 'Arma',
  'municion': 'Munición',
  'comunicacion': 'Comunicación',
  'acceso': 'Acceso (llaves, controles)',
  'proteccion': 'Protección',
  'equipo': 'Equipo',
  'documento': 'Documento',
  'otro': 'Otro',
};

const implTracking = <String, String>{
  'serial': 'Con número de serie',
  'count': 'Se cuenta (cantidad)',
  'unit': 'Solo se revisa',
};

class ImplType {
  const ImplType({
    required this.id,
    required this.name,
    required this.category,
    required this.severity,
    required this.tracking,
    required this.weapon,
    required this.active,
    this.sortOrder = 100,
  });

  final String id;
  final String name;
  final String category;
  final String severity;
  final String tracking;
  final bool weapon; // exige licencia de portación
  final bool active;
  final int sortOrder;
}

Future<List<ImplType>> loadImplTypes({String? companyId}) async {
  var q = supabase
      .from('implement_types')
      .select('id, company_id, name, category, severity, tracking, needs_weapon_license, active, sort_order');
  if (companyId != null) q = q.eq('company_id', companyId);
  final rows = await q.order('sort_order').order('name');
  return [
    for (final r in rows)
      ImplType(
        id: r['id'] as String,
        name: r['name'] as String,
        category: (r['category'] as String?) ?? 'otro',
        severity: (r['severity'] as String?) ?? 'yellow',
        tracking: (r['tracking'] as String?) ?? 'unit',
        weapon: (r['needs_weapon_license'] as bool?) ?? false,
        active: (r['active'] as bool?) ?? true,
        sortOrder: (r['sort_order'] as num?)?.toInt() ?? 100,
      ),
  ];
}

Future<void> saveImplType({
  String? id,
  required String companyId,
  required String name,
  required String category,
  required String severity,
  required String tracking,
  required bool weapon,
  required bool active,
}) async {
  final row = {
    'name': name,
    'category': category,
    'severity': severity,
    'tracking': tracking,
    'needs_weapon_license': weapon,
    'active': active,
  };
  try {
    if (id == null) {
      await supabase.from('implement_types').insert({...row, 'company_id': companyId});
    } else {
      await supabase.from('implement_types').update(row).eq('id', id);
    }
  } on PostgrestException catch (e) {
    if (e.code == '23505') throw const SiteError('Ya existe un implemento con ese nombre.');
    throw SiteError(siteDbError(e));
  }
}

// ───────────────────────── Sitio completo (para el formulario) ─────────────────────────

class EditImplement {
  EditImplement({
    this.id,
    required this.typeId,
    this.label = '',
    this.serial = '',
    this.quantity = 1,
    this.status = 'ok',
    this.statusNote,
  });

  String? id;
  String typeId;
  String label;
  String serial;
  int quantity;
  String status; // último estado conocido (solo lectura)
  String? statusNote;

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'type_id': typeId,
        'label': label.trim(),
        'serial': serial.trim(),
        'quantity': quantity,
      };
}

class EditPost {
  EditPost({
    this.id,
    this.name = '',
    this.coverFrom = '06:00',
    this.coverTo = '06:00',
    this.shiftHours = 12,
    Set<int>? days,
    this.guardsRequired = 1,
    this.orders = '',
    List<EditImplement>? implements,
    Set<String>? guards,
  })  : days = days ?? {1, 2, 3, 4, 5, 6, 7},
        implements = implements ?? [],
        guards = guards ?? {};

  String? id;
  String name;
  String coverFrom; // HH:MM
  String coverTo; // HH:MM (igual a coverFrom = 24 horas)
  int shiftHours;
  Set<int> days; // 1 = lunes … 7 = domingo
  int guardsRequired;
  String orders; // consignas
  List<EditImplement> implements;
  Set<String> guards; // guardas asignados (solo el admin los cambia)

  Map<String, dynamic> toJson({bool withGuards = false}) => {
        if (id != null) 'id': id,
        'name': name.trim(),
        'cover_from': coverFrom,
        'cover_to': coverTo,
        'shift_hours': shiftHours,
        'days': (days.toList()..sort()),
        'guards_required': guardsRequired,
        'orders': orders.trim(),
        'implements': [for (final i in implements) i.toJson()],
        if (withGuards) 'guards': guards.toList(),
      };
}

class EditContact {
  EditContact({
    this.id,
    this.name = '',
    this.jobTitle = '',
    this.phone = '',
    this.email = '',
    this.isAdmin = true,
    this.trainedAt,
  });

  String? id;
  String name;
  String jobTitle;
  String phone;
  String email;
  bool isAdmin;
  DateTime? trainedAt;

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'full_name': name.trim(),
        'job_title': jobTitle.trim(),
        'phone': phone.trim(),
        'email': email.trim(),
        'is_admin': isAdmin,
        'trained_at': trainedAt == null ? null : isoDate(trainedAt!),
      };
}

class SiteFull {
  SiteFull({
    this.id,
    this.companyId,
    this.name = '',
    this.address = '',
    this.lat,
    this.lng,
    this.radius = 100,
    this.clientId,
    this.proposedClientName = '',
    this.status = 'draft',
    this.active = false,
    this.proposedBy,
    this.reviewNote,
    this.roundsRequired = false,
    this.roundsEvery = 120,
    this.visitorControl = false,
    Map<String, dynamic>? survey,
    List<EditPost>? posts,
    List<EditContact>? contacts,
  })  : survey = survey ?? {},
        posts = posts ?? [],
        contacts = contacts ?? [];

  String? id;
  String? companyId;
  String name;
  String address;
  double? lat;
  double? lng;
  int radius;
  String? clientId;
  String proposedClientName;
  String status;
  bool active;
  String? proposedBy;
  String? reviewNote;
  bool roundsRequired;
  int roundsEvery;
  bool visitorControl;
  Map<String, dynamic> survey;
  List<EditPost> posts;
  List<EditContact> contacts;

  bool get approved => status == 'approved';

  Map<String, dynamic> toPayload({bool assignGuards = false}) => {
        if (companyId != null) 'company_id': companyId,
        'name': name.trim(),
        'address': address.trim(),
        'lat': lat,
        'lng': lng,
        'radius_m': radius,
        'client_id': clientId,
        'proposed_client_name': clientId == null ? proposedClientName.trim() : null,
        'rounds_required': roundsRequired,
        'rounds_every_minutes': roundsRequired ? roundsEvery : null,
        'visitor_control': visitorControl,
        'survey': survey,
        'assign_guards': assignGuards,
        'posts': [for (final p in posts) p.toJson(withGuards: assignGuards)],
        'contacts': [for (final c in contacts) c.toJson()],
      };
}

String _hhmm(Object? v) {
  final s = (v as String?) ?? '06:00';
  return s.length >= 5 ? s.substring(0, 5) : s;
}

Future<SiteFull> loadSiteFull(String id) async {
  final s = await supabase
      .from('sites')
      .select(
          'id, company_id, client_id, name, address, lat, lng, radius_m, active, status, proposed_by, review_note, '
          'proposed_client_name, rounds_required, rounds_every_minutes, visitor_control, survey')
      .eq('id', id)
      .single();
  final posts = await supabase
      .from('site_posts')
      .select('id, name, cover_from, cover_to, shift_hours, days, guards_required, orders, sort_order')
      .eq('site_id', id)
      .eq('active', true)
      .order('sort_order');
  final impl = await supabase
      .from('site_implements')
      .select('id, post_id, type_id, label, serial, quantity, status, status_note, created_at')
      .eq('site_id', id)
      .eq('active', true)
      .order('created_at');
  final contacts = await supabase
      .from('site_contacts')
      .select('id, full_name, job_title, phone, email, is_admin, trained_at, created_at')
      .eq('site_id', id)
      .eq('active', true)
      .order('created_at');
  List<Map<String, dynamic>> assign = const [];
  try {
    assign = await supabase
        .from('guard_sites')
        .select('guard_id, post_id')
        .eq('site_id', id)
        .eq('active', true);
  } catch (_) {
    // Si el rol no ve las asignaciones, el formulario sigue sin ellas.
  }

  final postList = <EditPost>[
    for (final p in posts)
      EditPost(
        id: p['id'] as String,
        name: (p['name'] as String?) ?? '',
        coverFrom: _hhmm(p['cover_from']),
        coverTo: _hhmm(p['cover_to']),
        shiftHours: (p['shift_hours'] as num?)?.toInt() ?? 12,
        days: {for (final x in (p['days'] as List<dynamic>? ?? const [])) (x as num).toInt()},
        guardsRequired: (p['guards_required'] as num?)?.toInt() ?? 1,
        orders: (p['orders'] as String?) ?? '',
        implements: [
          for (final i in impl.where((i) => i['post_id'] == p['id']))
            EditImplement(
              id: i['id'] as String,
              typeId: i['type_id'] as String,
              label: (i['label'] as String?) ?? '',
              serial: (i['serial'] as String?) ?? '',
              quantity: (i['quantity'] as num?)?.toInt() ?? 1,
              status: (i['status'] as String?) ?? 'ok',
              statusNote: i['status_note'] as String?,
            ),
        ],
        guards: {
          for (final a in assign.where((a) => a['post_id'] == p['id'])) a['guard_id'] as String,
        },
      ),
  ];
  // Guardas asignados al sitio sin puesto: quedan en el primero.
  final placed = {for (final p in postList) ...p.guards};
  if (postList.isNotEmpty) {
    for (final a in assign) {
      final g = a['guard_id'] as String;
      if (!placed.contains(g)) postList.first.guards.add(g);
    }
  }

  return SiteFull(
    id: s['id'] as String,
    companyId: s['company_id'] as String?,
    name: (s['name'] as String?) ?? '',
    address: (s['address'] as String?) ?? '',
    lat: (s['lat'] as num?)?.toDouble(),
    lng: (s['lng'] as num?)?.toDouble(),
    radius: (s['radius_m'] as num?)?.toInt() ?? 100,
    clientId: s['client_id'] as String?,
    proposedClientName: (s['proposed_client_name'] as String?) ?? '',
    status: (s['status'] as String?) ?? 'approved',
    active: (s['active'] as bool?) ?? false,
    proposedBy: s['proposed_by'] as String?,
    reviewNote: s['review_note'] as String?,
    roundsRequired: (s['rounds_required'] as bool?) ?? false,
    roundsEvery: (s['rounds_every_minutes'] as num?)?.toInt() ?? 120,
    visitorControl: (s['visitor_control'] as bool?) ?? false,
    survey: Map<String, dynamic>.from((s['survey'] as Map?) ?? const {}),
    posts: postList,
    contacts: [
      for (final c in contacts)
        EditContact(
          id: c['id'] as String,
          name: (c['full_name'] as String?) ?? '',
          jobTitle: (c['job_title'] as String?) ?? '',
          phone: (c['phone'] as String?) ?? '',
          email: (c['email'] as String?) ?? '',
          isAdmin: (c['is_admin'] as bool?) ?? false,
          trainedAt: parseIsoDate(c['trained_at']),
        ),
    ],
  );
}

// ───────────────────────── Guardar, aprobar, devolver ─────────────────────────

class SiteError implements Exception {
  const SiteError(this.message);
  final String message;
  @override
  String toString() => message;
}

String siteDbError(PostgrestException e) {
  // Las funciones del servidor responden en español con estos códigos.
  if (e.code == '22023' || e.code == 'P0001') return e.message;
  if (e.code == '42501') {
    return e.message.startsWith('permission denied') ? 'No tienes permiso para hacer esto.' : e.message;
  }
  return 'No se pudo guardar. Revisa tu conexión e intenta de nuevo.';
}

Future<String> saveSite(String? siteId, Map<String, dynamic> payload, {bool submit = false}) async {
  try {
    final id = await supabase.rpc('save_site', params: {
      'p_site_id': siteId,
      'p_payload': payload,
      'p_submit': submit,
    });
    return id as String;
  } on PostgrestException catch (e) {
    throw SiteError(siteDbError(e));
  }
}

Future<void> approveSite(String id, {String? clientId, String? newClientName}) async {
  try {
    await supabase.rpc('approve_site', params: {
      'p_site': id,
      'p_client': clientId,
      'p_new_client_name': newClientName,
    });
  } on PostgrestException catch (e) {
    throw SiteError(siteDbError(e));
  }
}

Future<void> returnSite(String id, String note) async {
  try {
    await supabase.rpc('return_site', params: {'p_site': id, 'p_note': note});
  } on PostgrestException catch (e) {
    throw SiteError(siteDbError(e));
  }
}

Future<void> setSiteActive(String id, bool active) async {
  try {
    await supabase.from('sites').update({'active': active}).eq('id', id);
  } on PostgrestException catch (e) {
    throw SiteError(siteDbError(e));
  }
}

/// Clientes para elegir al crear o proponer un sitio (id, nombre).
Future<List<(String, String)>> loadClientOptions(String? companyId) async {
  final rows = await supabase.rpc('client_options', params: {'p_company': companyId});
  return [
    for (final r in (rows as List<dynamic>))
      ((r as Map)['id'] as String, r['name'] as String),
  ];
}

// ───────────────────────── Horarios y consignas ─────────────────────────

class SchedulePreset {
  const SchedulePreset(this.label, this.from, this.to, this.hours);
  final String label;
  final String from;
  final String to;
  final int hours;
}

const schedulePresets = [
  SchedulePreset('24 h · turnos de 24 h (24x24)', '07:00', '07:00', 24),
  SchedulePreset('24 h · día y noche (turnos de 12 h)', '06:00', '06:00', 12),
  SchedulePreset('Solo de día · 06:00 a 18:00', '06:00', '18:00', 12),
  SchedulePreset('Solo de noche · 18:00 a 06:00', '18:00', '06:00', 12),
  SchedulePreset('Oficina · 07:00 a 17:00', '07:00', '17:00', 10),
];

int? presetIndexOf(EditPost p) {
  for (var i = 0; i < schedulePresets.length; i++) {
    final s = schedulePresets[i];
    if (s.from == p.coverFrom && s.to == p.coverTo && s.hours == p.shiftHours) return i;
  }
  return null;
}

String scheduleText(EditPost p) {
  final i = presetIndexOf(p);
  final base = i != null
      ? schedulePresets[i].label
      : (p.coverFrom == p.coverTo
          ? '24 h desde ${p.coverFrom} · turnos de ${p.shiftHours} h'
          : '${p.coverFrom} a ${p.coverTo} · turnos de ${p.shiftHours} h');
  return '$base · ${daysText(p.days)}';
}

const dayShort = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];

String daysText(Set<int> days) {
  final d = days.toList()..sort();
  if (d.length == 7) return 'todos los días';
  if (d.join() == '12345') return 'lunes a viernes';
  if (d.join() == '123456') return 'lunes a sábado';
  return d.map((x) => dayShort[x - 1]).join(' ');
}

const ordersTemplate = '1. Recibir el puesto revisando cada implemento; si algo falta, reportarlo antes de firmar.\n'
    '2. Pedir identificación a todo visitante y confirmar con el residente o la administración antes de dejarlo pasar.\n'
    '3. Anotar toda novedad en la bitácora con la hora.\n'
    '4. No abandonar el puesto sin relevo.\n'
    '5. Ante una emergencia, avisar al supervisor y llamar al 110 (PNC).';

// ───────────────────────── Levantamiento de seguridad ─────────────────────────

class SurveyQ {
  const SurveyQ(this.key, this.label, {this.options = const [], this.multi = false});
  final String key;
  final String label;
  final List<String> options; // vacío = texto libre
  final bool multi;
  bool get isText => options.isEmpty;
}

const surveyQuestions = [
  SurveyQ('tipo', 'Tipo de sitio',
      options: ['Condominio', 'Residencial', 'Ofibodega', 'Bodega', 'Oficina', 'Comercio', 'Otro']),
  SurveyQ('accesos_peatonales', 'Accesos peatonales', options: ['1', '2', '3 o más']),
  SurveyQ('accesos_vehiculares', 'Accesos vehiculares', options: ['Ninguno', '1', '2', '3 o más']),
  SurveyQ('perimetro', 'Perímetro', options: ['Muro', 'Malla', 'Mixto', 'Abierto']),
  SurveyQ('proteccion', 'Protección del perímetro',
      options: ['Concertina', 'Alambre de púas', 'Cerco eléctrico', 'Ninguna'], multi: true),
  SurveyQ('iluminacion', 'Iluminación de noche', options: ['Buena', 'Regular', 'Mala']),
  SurveyQ('camaras', 'Cámaras',
      options: ['No hay', 'Las ve el guarda', 'Las ve el cliente', 'Central de monitoreo']),
  SurveyQ('garita', 'Garita', options: ['Con baño', 'Sin baño', 'No hay']),
  SurveyQ('energia', 'Energía en la garita', options: ['Sí', 'Con planta o UPS', 'No']),
  SurveyQ('senal', 'Señal de celular en la garita', options: ['Buena', 'Débil', 'Sin señal']),
  SurveyQ('riesgo', 'Riesgo de la zona', options: ['Bajo', 'Medio', 'Alto']),
  SurveyQ('incidentes', 'Incidentes del último año',
      options: ['Ninguno', 'Robo', 'Intrusión', 'Asalto', 'Otro'], multi: true),
  SurveyQ('proveedores', 'Ingreso de proveedores o mensajeros', options: ['A diario', 'A veces', 'Nunca']),
  SurveyQ('pnc', 'PNC más cercana (dirección y teléfono)'),
  SurveyQ('emergencias', 'Bomberos y hospital más cercanos'),
  SurveyQ('horario', 'Horario de operación del cliente'),
  SurveyQ('observaciones', 'Observaciones'),
];

int surveyAnswered(Map<String, dynamic> s) {
  var n = 0;
  for (final q in surveyQuestions) {
    final v = s[q.key];
    if (v is String && v.trim().isNotEmpty) n++;
    if (v is List && v.isNotEmpty) n++;
  }
  return n;
}

String surveyValueText(Object? v) {
  if (v is List) return v.join(', ');
  if (v is String) return v;
  return '';
}
