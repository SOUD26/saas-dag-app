// Formulario de persona: alta (cuenta + ficha + documentos + foto) y edición de la ficha.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../theme.dart';
import 'admin_data.dart';
import 'admin_sheets.dart' show Reload;
import 'admin_ui.dart';
import 'staff_file.dart';

const _newRoles = <(String, String)>[
  ('guard', 'Guarda'),
  ('supervisor', 'Supervisor'),
  ('company_admin', 'Administrador'),
  ('client', 'Cliente (condominio u oficina)'),
  ('resident', 'Usuario (condómino o residente)'),
];

bool _isStaffRole(String r) => r == 'guard' || r == 'supervisor' || r == 'company_admin';
bool _isFieldRole(String r) => r == 'guard' || r == 'supervisor';

/// Abre el formulario. Sin [person]: alta de usuario. Con [person]: su ficha.
Future<void> openStaffForm(
  BuildContext context, {
  required AdminData d,
  required String companyId,
  required Reload reload,
  AStaff? person,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => StaffFormPage(d: d, companyId: companyId, reload: reload, person: person),
    ),
  );
}

// ───────────────────────── Campos de texto con formato ─────────────────────────

/// Escribe "15031990" y queda "15/03/1990".
class _DateFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = onlyDigits(newValue.text);
    final b = StringBuffer();
    for (var i = 0; i < digits.length && i < 8; i++) {
      if (i == 2 || i == 4) b.write('/');
      b.write(digits[i]);
    }
    final t = b.toString();
    return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }
}

/// DPI como viene en la tarjeta: "1234 56789 0101".
class _DpiFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = onlyDigits(newValue.text);
    final b = StringBuffer();
    for (var i = 0; i < digits.length && i < 13; i++) {
      if (i == 4 || i == 9) b.write(' ');
      b.write(digits[i]);
    }
    final t = b.toString();
    return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }
}

/// Un documento en edición: número y fechas, y si se registra como renovación.
class _DocEdit {
  _DocEdit(StaffDoc? doc)
      : id = doc?.id,
        current = doc,
        number = TextEditingController(text: doc?.number ?? ''),
        expires = TextEditingController(text: doc?.expiresOn == null ? '' : fmtDate(doc!.expiresOn!));

  String? id;
  StaffDoc? current;
  final TextEditingController number;
  final TextEditingController expires;
  bool renew = false;

  bool get isEmpty => number.text.trim().isEmpty && expires.text.trim().isEmpty;

  void dispose() {
    number.dispose();
    expires.dispose();
  }
}

// ───────────────────────── Página ─────────────────────────

class StaffFormPage extends StatefulWidget {
  const StaffFormPage({
    super.key,
    required this.d,
    required this.companyId,
    required this.reload,
    this.person,
  });

  final AdminData d;
  final String companyId;
  final Reload reload;
  final AStaff? person;

  @override
  State<StaffFormPage> createState() => _StaffFormPageState();
}

class _StaffFormPageState extends State<StaffFormPage> {
  // Cuenta (solo alta)
  late String _role = widget.person?.role ?? 'guard';
  final _email = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _clientId;

  // Ficha
  final _fullName = TextEditingController(); // cliente / usuario
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _code = TextEditingController();
  final _dpi = TextEditingController();
  final _birth = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  final _dept = TextEditingController();
  final _muni = TextEditingController();
  final _hire = TextEditingController(text: fmtDate(todayDate()));
  final _emName = TextEditingController();
  final _emPhone = TextEditingController();
  final _emRel = TextEditingController();
  bool _weapon = false;
  bool _moto = false;
  bool _vehicle = false;
  final Map<String, _DocEdit> _docs = {
    for (final k in const [
      DocKey.dpi,
      DocKey.weapon,
      DocKey.moto,
      DocKey.vehicle,
      DocKey.digessp,
      DocKey.criminal,
      DocKey.police,
    ])
      k: _DocEdit(null),
  };

  // Foto
  Uint8List? _photo;
  String _photoName = 'foto.jpg';
  bool _photoSaved = false;
  String? _avatarPath;
  String? _avatarUrl;

  // Estado
  StaffFile? _file;
  String? _createdId; // alta: cuenta ya creada (si algo falla después, no se vuelve a crear)
  bool _loading = false;
  bool _busy = false;
  String? _error;
  final Map<String, String> _errs = {};

  bool get _isNew => widget.person == null;
  bool get _staff => _isStaffRole(_role);
  bool get _field => _isFieldRole(_role);
  String? get _profileId => widget.person?.id ?? _createdId;

  @override
  void initState() {
    super.initState();
    if (!_isNew) {
      _loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final f = await loadStaffFile(widget.person!.id);
      final url = await signedAvatarUrl(f.avatarPath);
      if (!mounted) return;
      setState(() {
        _file = f;
        _role = f.role;
        _fullName.text = f.fullName;
        _first.text = f.firstNames;
        _last.text = f.lastNames;
        _code.text = f.employeeCode ?? '';
        _dpi.text = fmtDpi(f.dpi);
        _birth.text = f.birthDate == null ? '' : fmtDate(f.birthDate!);
        _phone.text = f.phone ?? '';
        _address.text = f.address ?? '';
        _dept.text = f.department ?? '';
        _muni.text = f.municipality ?? '';
        _hire.text = f.hireDate == null ? '' : fmtDate(f.hireDate!);
        _emName.text = f.emergencyName ?? '';
        _emPhone.text = f.emergencyPhone ?? '';
        _emRel.text = f.emergencyRelation ?? '';
        _weapon = f.carriesWeapon || f.docs.containsKey(DocKey.weapon);
        _moto = f.drivesMotorcycle || f.docs.containsKey(DocKey.moto);
        _vehicle = f.drivesVehicle || f.docs.containsKey(DocKey.vehicle);
        for (final k in _docs.keys.toList()) {
          _docs[k]!.dispose();
          _docs[k] = _DocEdit(f.docs[k]);
        }
        _avatarPath = f.avatarPath;
        _avatarUrl = url;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo abrir la ficha. Revisa tu conexión.';
      });
    }
  }

  @override
  void dispose() {
    for (final c in [
      _email, _user, _pass, _fullName, _first, _last, _code, _dpi, _birth, _phone,
      _address, _dept, _muni, _hire, _emName, _emPhone, _emRel,
    ]) {
      c.dispose();
    }
    for (final e in _docs.values) {
      e.dispose();
    }
    super.dispose();
  }

  // ───────────── Foto ─────────────

  Future<void> _pickPhoto(ImageSource source) async {
    try {
      final x = await ImagePicker().pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 80,
      );
      if (x == null) return;
      final bytes = await x.readAsBytes();
      if (!mounted) return;
      setState(() {
        _photo = bytes;
        _photoName = x.name;
        _photoSaved = false;
        _errs.remove('photo');
      });
    } catch (_) {
      if (mounted) toast(context, 'No se pudo abrir la cámara o la galería.');
    }
  }

  // ───────────── Validación ─────────────

  String? _t(TextEditingController c) {
    final v = c.text.trim();
    return v.isEmpty ? null : v;
  }

  bool _validate() {
    _errs.clear();
    void need(String key, TextEditingController c, String msg) {
      if (c.text.trim().isEmpty) _errs[key] = msg;
    }

    DateTime? date(String key, TextEditingController c, {bool required = false}) {
      final v = c.text.trim();
      if (v.isEmpty) {
        if (required) _errs[key] = 'Escribe la fecha (dd/mm/aaaa).';
        return null;
      }
      final d = parseDmy(v);
      if (d == null) _errs[key] = 'Fecha inválida. Usa dd/mm/aaaa.';
      return d;
    }

    void phone(String key, TextEditingController c, {bool required = false}) {
      final n = onlyDigits(c.text);
      if (n.isEmpty) {
        if (required) _errs[key] = 'Escribe el teléfono.';
      } else if (n.length < 8) {
        _errs[key] = 'Mínimo 8 dígitos.';
      }
    }

    if (_isNew) {
      if (_role == 'guard') {
        if (!RegExp(r'^[a-z0-9._-]{3,30}$').hasMatch(_user.text.trim().toLowerCase())) {
          _errs['user'] = '3 a 30 caracteres: letras, números, punto o guion.';
        }
        if (_pass.text.length < 8) _errs['pass'] = 'Mínimo 8 caracteres.';
      } else {
        if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim())) {
          _errs['email'] = 'Correo inválido.';
        }
        if (_role == 'supervisor' && _pass.text.length < 8) {
          _errs['pass'] = 'El supervisor entra con contraseña: mínimo 8 caracteres.';
        } else if (_pass.text.isNotEmpty && _pass.text.length < 8) {
          _errs['pass'] = 'Mínimo 8 caracteres (o déjala vacía para entrar con Google).';
        }
      }
      if ((_role == 'client' || _role == 'resident') && _clientId == null) {
        _errs['client'] = 'Elige a qué cliente pertenece.';
      }
    }

    if (!_staff) {
      need('fullName', _fullName, 'Escribe el nombre completo.');
      phone('phone', _phone);
      return _errs.isEmpty;
    }

    need('first', _first, 'Escribe los nombres.');
    need('last', _last, 'Escribe los apellidos.');
    final dpi = onlyDigits(_dpi.text);
    if (dpi.length != 13) _errs['dpi'] = 'El DPI tiene 13 dígitos.';
    final birth = date('birth', _birth, required: true);
    if (birth != null) {
      final t = todayDate();
      final adult = DateTime(t.year - 18, t.month, t.day);
      if (birth.isAfter(adult)) _errs['birth'] = 'Debe ser mayor de edad.';
      if (birth.year < 1900) _errs['birth'] = 'Revisa el año.';
    }
    phone('phone', _phone, required: true);
    need('address', _address, 'Escribe la dirección.');
    date('hire', _hire);
    phone('emPhone', _emPhone);

    if (_field && _photo == null && _avatarPath == null) {
      _errs['photo'] = 'La foto es obligatoria para guardas y supervisores.';
    }

    void doc(String key, {bool required = false, bool numberRequired = false}) {
      final e = _docs[key]!;
      final hasData = !e.isEmpty;
      if (!required && !hasData) return;
      if (numberRequired && e.number.text.trim().isEmpty) _errs['$key.number'] = 'Escribe el número.';
      final exp = date('$key.expires', e.expires, required: true);
      if (exp != null && exp.year < 2000) _errs['$key.expires'] = 'Revisa el año.';
    }

    doc(DocKey.dpi, required: true);
    if (_field) {
      if (_weapon) doc(DocKey.weapon, required: true, numberRequired: true);
      if (_moto) doc(DocKey.moto, required: true, numberRequired: true);
      if (_vehicle) doc(DocKey.vehicle, required: true, numberRequired: true);
      doc(DocKey.digessp);
    }
    doc(DocKey.criminal);
    doc(DocKey.police);
    return _errs.isEmpty;
  }

  // ───────────── Guardar ─────────────

  Map<String, dynamic> _record() {
    String? iso(TextEditingController c) {
      final d = parseDmy(c.text);
      return d == null ? null : isoDate(d);
    }

    return {
      'first_names': _first.text.trim(),
      'last_names': _last.text.trim(),
      'employee_code': _t(_code),
      'dpi': onlyDigits(_dpi.text),
      'birth_date': iso(_birth),
      'address': _t(_address),
      'department': _t(_dept),
      'municipality': _t(_muni),
      'emergency_contact_name': _t(_emName),
      'emergency_contact_phone': _t(_emPhone),
      'emergency_contact_relation': _t(_emRel),
      'hire_date': iso(_hire),
      'carries_weapon': _field && _weapon,
      'drives_motorcycle': _field && _moto,
      'drives_vehicle': _field && _vehicle,
    };
  }

  List<Map<String, dynamic>> _documents() {
    final out = <Map<String, dynamic>>[];
    void add(String key, {String? number}) {
      final e = _docs[key]!;
      final nro = number ?? _t(e.number);
      final exp = parseDmy(e.expires.text);
      if (nro == null && exp == null) return;
      final cur = e.current;
      final asNew = e.id == null || e.renew;
      if (!asNew && cur != null && cur.number == nro && cur.expiresOn == exp) return; // sin cambios
      out.add({
        if (!asNew) 'id': e.id,
        'type_key': key,
        'number': nro,
        'expires_on': exp == null ? null : isoDate(exp),
        if (!asNew) 'issued_on': cur?.issuedOn == null ? null : isoDate(cur!.issuedOn!),
      });
    }

    add(DocKey.dpi, number: onlyDigits(_dpi.text));
    if (_field) {
      if (_weapon) add(DocKey.weapon);
      if (_moto) add(DocKey.moto);
      if (_vehicle) add(DocKey.vehicle);
      add(DocKey.digessp);
    }
    add(DocKey.criminal);
    add(DocKey.police);
    return out;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_validate()) {
      setState(() => _error = 'Revisa los campos marcados en rojo.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 1) DPI o código repetidos: se revisa antes de crear la cuenta.
      if (_staff) {
        final problem = await staffPrecheck(
          widget.companyId,
          dpi: onlyDigits(_dpi.text),
          employeeCode: _t(_code),
          profileId: _profileId,
        );
        if (problem != null) throw StaffFileError(problem);
      }

      // 2) Cuenta (solo la primera vez).
      if (_isNew && _createdId == null) {
        final name = _staff ? '${_first.text.trim()} ${_last.text.trim()}' : _fullName.text.trim();
        final newId = await createUserAccount(
          role: _role,
          companyId: widget.companyId,
          fullName: name,
          email: _role == 'guard' ? null : _email.text.trim(),
          username: _role == 'guard' ? _user.text.trim().toLowerCase() : null,
          password: _pass.text,
          clientId: (_role == 'client' || _role == 'resident') ? _clientId : null,
        );
        setState(() => _createdId = newId);
      }
      final id = _profileId!;

      // 3) Ficha, teléfono y documentos: todo o nada.
      if (_staff) {
        await saveStaffFile(id, phone: _t(_phone), record: _record(), documents: _documents());
        await _syncDocIds(id); // si algo falla después y se reintenta, no se duplican documentos
      } else {
        if (!_isNew && _fullName.text.trim() != (_file?.fullName ?? '')) {
          await saveFullName(id, _fullName.text.trim());
        }
        await saveStaffFile(id, phone: _t(_phone));
      }

      // 4) Foto.
      if (_photo != null && !_photoSaved) {
        await uploadAvatar(id, _photo!, _photoName, oldPath: _avatarPath);
        _photoSaved = true;
      }

      await widget.reload();
      if (!mounted) return;
      Navigator.of(context).pop();
      toast(context, _isNew ? 'Usuario creado con su ficha.' : 'Ficha guardada.');
    } on UserCreateError catch (e) {
      _fail(e.message);
    } on StaffFileError catch (e) {
      _fail(_createdId != null && _isNew
          ? 'La cuenta ya se creó, pero falta guardar la ficha: ${e.message} Corrige y vuelve a guardar.'
          : e.message);
    } catch (_) {
      _fail('No se pudo guardar. Revisa tu conexión e intenta de nuevo.');
    }
  }

  Future<void> _syncDocIds(String id) async {
    try {
      final f = await loadStaffFile(id);
      for (final e in _docs.entries) {
        final doc = f.docs[e.key];
        e.value
          ..id = doc?.id
          ..current = doc
          ..renew = false;
      }
      _file = f;
    } catch (_) {
      // Si no se pudo releer, el siguiente guardado igual funciona (puede repetir un documento).
    }
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = msg;
    });
  }

  // ───────────── Interfaz ─────────────

  @override
  Widget build(BuildContext context) {
    final title = _isNew ? 'Nuevo usuario' : (widget.person?.name ?? 'Ficha');
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: Text(title),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.navy))
          : LayoutBuilder(
              builder: (context, c) {
                final side = ((c.maxWidth - 720) / 2).clamp(16.0, double.infinity);
                return ListView(
                  padding: EdgeInsets.fromLTRB(side, 16, side, 32),
                  children: _sections(),
                );
              },
            ),
      bottomNavigationBar: _loading
          ? null
          : SafeArea(
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
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
                      onPressed: _busy ? null : _save,
                      child: _busy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                            )
                          : Text(_isNew && _createdId == null ? 'Crear usuario' : 'Guardar ficha'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  List<Widget> _sections() {
    final clients = widget.d.clients.where((c) => c.active).toList();
    return [
      if (_isNew && _createdId == null) ...[
        DropdownButtonFormField<String>(
          // ignore: deprecated_member_use
          value: _role,
          decoration: const InputDecoration(labelText: 'Rol'),
          items: [
            for (final r in _newRoles) DropdownMenuItem(value: r.$1, child: Text(r.$2)),
          ],
          onChanged: _busy
              ? null
              : (v) => setState(() {
                    _role = v ?? 'guard';
                    _errs.clear();
                    _error = null;
                  }),
        ),
        const SizedBox(height: 16),
      ] else if (widget.person?.login != null || _file?.login != null) ...[
        _Card(
          title: 'Cuenta',
          children: [
            _info('Rol', roleLabels[_role] ?? _role),
            _info(_role == 'guard' ? 'Usuario' : 'Correo', widget.person?.login ?? _file?.login ?? ''),
          ],
        ),
      ],
      if (_staff) ...[
        _Card(
          title: 'Foto de perfil${_field ? ' *' : ''}',
          subtitle: 'Para que el supervisor y el guarda se reconozcan en el sitio.',
          children: [_photoRow()],
        ),
        _Card(
          title: 'Datos personales',
          children: [
            _text(_first, 'Nombres *', 'first', caps: true),
            _text(_last, 'Apellidos *', 'last', caps: true),
            _dpiField(),
            _date(_birth, 'Fecha de nacimiento *', 'birth'),
            _text(_phone, 'Teléfono *', 'phone', keyboard: TextInputType.phone),
            _text(_address, 'Dirección *', 'address', caps: true),
            Row(
              children: [
                Expanded(child: _text(_dept, 'Departamento', 'dept', caps: true)),
                const SizedBox(width: 12),
                Expanded(child: _text(_muni, 'Municipio', 'muni', caps: true)),
              ],
            ),
            Row(
              children: [
                Expanded(child: _text(_code, 'Código de empleado', 'code')),
                const SizedBox(width: 12),
                Expanded(child: _date(_hire, 'Fecha de ingreso', 'hire')),
              ],
            ),
          ],
        ),
      ] else
        _Card(
          title: 'Datos',
          children: [
            _text(_fullName, 'Nombre completo *', 'fullName', caps: true),
            _text(_phone, 'Teléfono', 'phone', keyboard: TextInputType.phone),
          ],
        ),
      if (_isNew && _createdId == null) _accountCard(clients),
      if (_staff) _documentsCard(),
      if (_staff)
        _Card(
          title: 'Contacto de emergencia',
          subtitle: 'A quién avisar si le pasa algo. El supervisor lo puede ver.',
          children: [
            _text(_emName, 'Nombre', 'emName', caps: true),
            Row(
              children: [
                Expanded(child: _text(_emPhone, 'Teléfono', 'emPhone', keyboard: TextInputType.phone)),
                const SizedBox(width: 12),
                Expanded(child: _text(_emRel, 'Parentesco', 'emRel', caps: true)),
              ],
            ),
          ],
        ),
    ];
  }

  Widget _accountCard(List<AClient> clients) {
    final guard = _role == 'guard';
    final needsClient = _role == 'client' || _role == 'resident';
    return _Card(
      title: 'Cuenta',
      subtitle: guard
          ? 'El guarda entra con usuario y contraseña en el teléfono del sitio.'
          : 'Con este correo entra a la app.',
      children: [
        if (guard)
          _text(_user, 'Usuario *', 'user', help: 'Letras minúsculas, números, punto o guion')
        else
          _text(_email, 'Correo *', 'email', keyboard: TextInputType.emailAddress),
        _text(
          _pass,
          _role == 'guard' || _role == 'supervisor' ? 'Contraseña *' : 'Contraseña (opcional)',
          'pass',
          help: _role == 'guard' || _role == 'supervisor'
              ? 'Mínimo 8 caracteres. Entrégasela a la persona.'
              : 'Mínimo 8. Si la dejas vacía, entra con Google.',
        ),
        if (needsClient)
          clients.isEmpty
              ? const Text(
                  'Primero crea un cliente en la pestaña Clientes.',
                  style: TextStyle(color: AppColors.danger),
                )
              : Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: DropdownButtonFormField<String>(
                    // ignore: deprecated_member_use
                    value: _clientId,
                    decoration: InputDecoration(labelText: 'Cliente *', errorText: _errs['client']),
                    items: [
                      for (final c in clients) DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: _busy ? null : (v) => setState(() => _clientId = v),
                  ),
                ),
      ],
    );
  }

  Widget _documentsCard() {
    return _Card(
      title: 'Documentos y vencimientos',
      subtitle: 'Te avisamos 30 días antes de que venza cualquiera.',
      children: [
        _docBlock(DocKey.dpi, 'DPI', numberField: false),
        if (_field) ...[
          _toggle('Porta arma', 'Exige licencia de portación de DIGECAM vigente.', _weapon,
              (v) => setState(() => _weapon = v)),
          if (_weapon) _docBlock(DocKey.weapon, 'Licencia de portación de arma (DIGECAM)', numberRequired: true),
          _toggle('Conduce moto', 'Exige licencia tipo M vigente.', _moto, (v) => setState(() => _moto = v)),
          if (_moto) _docBlock(DocKey.moto, 'Licencia de moto (tipo M)', numberRequired: true),
          _toggle('Conduce vehículo', 'Exige licencia tipo A, B o C vigente.', _vehicle,
              (v) => setState(() => _vehicle = v)),
          if (_vehicle) _docBlock(DocKey.vehicle, 'Licencia de vehículo (tipo A, B o C)', numberRequired: true),
          const Divider(height: 28),
          _docBlock(DocKey.digessp, 'Credencial de agente (DIGESSP)', optional: true),
        ],
        _docBlock(DocKey.criminal, 'Antecedentes penales', numberField: false, optional: true),
        _docBlock(DocKey.police, 'Antecedentes policíacos', numberField: false, optional: true),
      ],
    );
  }

  Widget _toggle(String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      value: value,
      onChanged: _busy ? null : onChanged,
    );
  }

  Widget _docBlock(
    String key,
    String title, {
    bool numberField = true,
    bool numberRequired = false,
    bool optional = false,
  }) {
    final e = _docs[key]!;
    final cur = e.current;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  optional ? '$title (opcional)' : title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (cur?.expiresOn != null && !e.renew) _expiryPill(cur!.expiresOn!),
              if (cur != null && !e.renew)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            e.renew = true;
                            e.number.clear();
                            e.expires.clear();
                          }),
                  child: const Text('Renovar'),
                ),
            ],
          ),
          if (e.renew)
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text(
                'Se guardará como documento nuevo; el anterior queda en el historial.',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
          const SizedBox(height: 6),
          if (numberField)
            Row(
              children: [
                Expanded(child: _text(e.number, numberRequired ? 'Número *' : 'Número', '$key.number')),
                const SizedBox(width: 12),
                Expanded(child: _date(e.expires, optional ? 'Vence' : 'Vence *', '$key.expires')),
              ],
            )
          else
            _date(e.expires, optional ? 'Vence' : 'Vence *', '$key.expires'),
        ],
      ),
    );
  }

  Widget _expiryPill(DateTime exp) {
    final n = daysFromToday(exp);
    if (n < 0) return const Pill('Vencido', AppColors.danger);
    if (n <= 30) return Pill('Vence en $n d', kWarn);
    return const Pill('Vigente', kOk);
  }

  Widget _photoRow() {
    final ImageProvider? img = _photo != null
        ? MemoryImage(_photo!)
        : (_avatarUrl != null ? NetworkImage(_avatarUrl!) : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 44,
              backgroundColor: AppColors.navy.withValues(alpha: 0.08),
              foregroundImage: img,
              child: const Icon(Icons.person_rounded, size: 44, color: AppColors.navy),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    style: smallOutline(),
                    onPressed: _busy ? null : () => _pickPhoto(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_rounded),
                    label: const Text('Tomar foto'),
                  ),
                  OutlinedButton.icon(
                    style: smallOutline(),
                    onPressed: _busy ? null : () => _pickPhoto(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_rounded),
                    label: const Text('Galería'),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (_errs['photo'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_errs['photo']!, style: const TextStyle(color: AppColors.danger, fontSize: 12)),
          ),
      ],
    );
  }

  Widget _dpiField() {
    final digits = onlyDigits(_dpi.text);
    final warn = digits.length == 13 && !dpiLooksValid(digits);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _dpi,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        inputFormatters: [_DpiFormatter()],
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: 'DPI (CUI) *',
          hintText: '1234 56789 0101',
          errorText: _errs['dpi'],
          helperText: warn ? 'Revisa el número: el dígito verificador no cuadra.' : null,
          helperStyle: const TextStyle(color: kWarn),
        ),
      ),
    );
  }

  Widget _text(
    TextEditingController c,
    String label,
    String key, {
    TextInputType? keyboard,
    bool caps = false,
    String? help,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        enabled: !_busy,
        keyboardType: keyboard,
        autocorrect: false,
        textCapitalization: caps ? TextCapitalization.words : TextCapitalization.none,
        decoration: InputDecoration(labelText: label, helperText: help, errorText: _errs[key]),
      ),
    );
  }

  Widget _date(TextEditingController c, String label, String key) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        inputFormatters: [_DateFormatter()],
        decoration: InputDecoration(labelText: label, hintText: 'dd/mm/aaaa', errorText: _errs[key]),
      ),
    );
  }

  Widget _info(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(width: 90, child: Text(k, style: const TextStyle(color: AppColors.muted))),
            Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
          ],
        ),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children, this.subtitle});
  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle!, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            ],
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Documentos por vencer ─────────────────────────

Future<void> openDocAlerts(
  BuildContext context, {
  required AdminData d,
  required String companyId,
  required Reload reload,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => DocAlertsPage(d: d, companyId: companyId, reload: reload),
    ),
  );
}

class DocAlertsPage extends StatefulWidget {
  const DocAlertsPage({super.key, required this.d, required this.companyId, required this.reload});
  final AdminData d;
  final String companyId;
  final Reload reload;

  @override
  State<DocAlertsPage> createState() => _DocAlertsPageState();
}

class _DocAlertsPageState extends State<DocAlertsPage> {
  List<DocAlert>? _alerts;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final a = await loadDocAlerts(widget.companyId);
      if (!mounted) return;
      setState(() {
        _alerts = a;
        _failed = false;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _open(DocAlert a) async {
    if (a.ownerKind != 'staff') {
      toast(context, 'Los documentos de la empresa y de los clientes se cargan en sus fichas (siguiente paso).');
      return;
    }
    final person = widget.d.staffById(a.ownerId);
    if (person == null) return;
    await openStaffForm(context, d: widget.d, companyId: widget.companyId, reload: widget.reload, person: person);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final a = _alerts;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: const Text('Documentos'),
      ),
      body: a == null
          ? Center(
              child: _failed
                  ? OutlinedButton(style: smallOutline(), onPressed: _load, child: const Text('Reintentar'))
                  : const CircularProgressIndicator(color: AppColors.navy),
            )
          : AdminPage(
              onRefresh: _load,
              children: [
                if (a.isEmpty)
                  const Panel(
                    child: EmptyState(
                      Icons.verified_rounded,
                      'Todo al día: no hay documentos vencidos, por vencer ni faltantes.',
                    ),
                  ),
                ..._group('Vencidos', a.where((x) => x.status == DocStatus.expired).toList()),
                ..._group('Faltan', a.where((x) => x.status == DocStatus.missing).toList()),
                ..._group('Por vencer en 30 días', a.where((x) => x.status == DocStatus.expiring).toList()),
              ],
            ),
    );
  }

  List<Widget> _group(String title, List<DocAlert> items) {
    if (items.isEmpty) return const [];
    return [
      SectionHead('$title (${items.length})'),
      for (final x in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Panel(
            onTap: () => _open(x),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  x.status == DocStatus.expiring ? Icons.schedule_rounded : Icons.error_rounded,
                  color: x.status == DocStatus.expiring ? kWarn : AppColors.danger,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(x.ownerName, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('${x.typeName} · ${x.when}',
                          style: const TextStyle(color: AppColors.muted, fontSize: 13)),
                    ],
                  ),
                ),
                if (x.ownerRole != null) Pill(roleLabels[x.ownerRole] ?? x.ownerRole!, AppColors.navy),
              ],
            ),
          ),
        ),
      const SizedBox(height: 8),
    ];
  }
}
