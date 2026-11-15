// Alta y edición de una empresa de seguridad (solo súper admin).
import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../widgets/formatters.dart';
import '../admin/admin_ui.dart';
import '../admin/staff_file.dart';
import 'super_data.dart';

/// Abre el formulario. Sin [company]: empresa nueva. Devuelve el id guardado (o null si se canceló).
Future<String?> openCompanyForm(BuildContext context, {CompanyInfo? company}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(builder: (_) => CompanyFormPage(company: company)),
  );
}

class CompanyFormPage extends StatefulWidget {
  const CompanyFormPage({super.key, this.company});
  final CompanyInfo? company;

  @override
  State<CompanyFormPage> createState() => _CompanyFormPageState();
}

class _CompanyFormPageState extends State<CompanyFormPage> {
  late final CompanyInfo? c = widget.company;

  late final _name = TextEditingController(text: c?.name ?? '');
  late final _legal = TextEditingController(text: c?.legalName ?? '');
  late final _nit = TextEditingController(text: c?.nit ?? '');
  late final _rep = TextEditingController(text: c?.legalRep ?? '');
  late final _phone = TextEditingController(text: c?.phone ?? '');
  late final _email = TextEditingController(text: c?.email ?? '');
  late final _address = TextEditingController(text: c?.address ?? '');
  late final _dept = TextEditingController(text: c?.department ?? '');
  late final _muni = TextEditingController(text: c?.municipality ?? '');

  late final _licNumber = TextEditingController(text: c?.licenseNumber ?? '');
  late final _licExpires =
      TextEditingController(text: c?.licenseExpires == null ? '' : fmtDate(c!.licenseExpires!));
  bool _licRenew = false;

  late String _status = c?.subStatus ?? 'trial';
  late final _plan = TextEditingController(text: c?.plan ?? '');
  late final _fee = TextEditingController(text: c?.fee == null ? '' : c!.fee!.toStringAsFixed(2));
  late final _billingDay = TextEditingController(text: c?.billingDay?.toString() ?? '');
  late final _started = TextEditingController(
      text: c?.startedOn == null ? fmtDate(todayDate()) : fmtDate(c!.startedOn!));
  late final _trialEnds =
      TextEditingController(text: c?.trialEndsOn == null ? '' : fmtDate(c!.trialEndsOn!));
  late final _notes = TextEditingController(text: c?.notes ?? '');

  final Map<String, String> _errs = {};
  bool _busy = false;
  String? _error;

  bool get _isNew => c == null;

  @override
  void dispose() {
    for (final x in [
      _name, _legal, _nit, _rep, _phone, _email, _address, _dept, _muni,
      _licNumber, _licExpires, _plan, _fee, _billingDay, _started, _trialEnds, _notes,
    ]) {
      x.dispose();
    }
    super.dispose();
  }

  String? _t(TextEditingController x) {
    final v = x.text.trim();
    return v.isEmpty ? null : v;
  }

  DateTime? _date(String key, TextEditingController x, {bool required = false}) {
    final v = x.text.trim();
    if (v.isEmpty) {
      if (required) _errs[key] = 'Escribe la fecha (dd/mm/aaaa).';
      return null;
    }
    final d = parseDmy(v);
    if (d == null) _errs[key] = 'Fecha inválida. Usa dd/mm/aaaa.';
    return d;
  }

  bool _validate() {
    _errs.clear();
    if (_name.text.trim().isEmpty) _errs['name'] = 'Escribe el nombre de la empresa.';
    final phone = onlyDigits(_phone.text);
    if (phone.isNotEmpty && phone.length < 8) _errs['phone'] = 'Mínimo 8 dígitos.';
    final email = _email.text.trim();
    if (email.isNotEmpty && !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      _errs['email'] = 'Correo inválido.';
    }
    if (_t(_licNumber) != null || _t(_licExpires) != null) {
      _date('licExpires', _licExpires, required: true);
    }
    final fee = _fee.text.trim().replaceAll(',', '');
    if (fee.isNotEmpty && (double.tryParse(fee) == null || double.parse(fee) < 0)) {
      _errs['fee'] = 'Escribe solo el número (ej. 1500).';
    }
    final day = _billingDay.text.trim();
    if (day.isNotEmpty) {
      final n = int.tryParse(day);
      if (n == null || n < 1 || n > 28) _errs['billingDay'] = 'Del 1 al 28.';
    }
    _date('started', _started);
    _date('trialEnds', _trialEnds);
    return _errs.isEmpty;
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
    String? iso(TextEditingController x) {
      final d = parseDmy(x.text);
      return d == null ? null : isoDate(d);
    }

    final fee = _fee.text.trim().replaceAll(',', '');
    try {
      final id = await saveCompany(
        id: c?.id,
        company: {
          'name': _name.text.trim(),
          'legal_name': _t(_legal),
          'nit': _t(_nit),
          'legal_rep_name': _t(_rep),
          'phone': _t(_phone),
          'email': _t(_email),
          'address': _t(_address),
          'department': _t(_dept),
          'municipality': _t(_muni),
        },
        subscription: {
          'status': _status,
          'plan': _t(_plan),
          'monthly_fee': fee.isEmpty ? null : double.parse(fee),
          'billing_day': _billingDay.text.trim().isEmpty ? null : int.parse(_billingDay.text.trim()),
          'started_on': iso(_started),
          'trial_ends_on': iso(_trialEnds),
          'notes': _t(_notes),
        },
        licenseId: c?.licenseId,
        licenseNumber: _t(_licNumber),
        licenseExpires: parseDmy(_licExpires.text),
        licenseRenew: _licRenew,
      );
      if (!mounted) return;
      Navigator.of(context).pop(id);
    } on CompanyError catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail('No se pudo guardar. Revisa tu conexión e intenta de nuevo.');
    }
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    final nitDigits = _nit.text.trim();
    final nitWarn = nitDigits.length >= 2 && !nitLooksValid(nitDigits);
    final lic = c?.licenseExpires;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        title: Text(_isNew ? 'Nueva empresa' : c!.name),
      ),
      body: LayoutBuilder(
        builder: (context, box) {
          final side = ((box.maxWidth - 720) / 2).clamp(16.0, double.infinity);
          return ListView(
            padding: EdgeInsets.fromLTRB(side, 16, side, 32),
            children: [
              FormCard(
                title: 'Datos de la empresa',
                children: [
                  _text(_name, 'Nombre comercial *', 'name', caps: true),
                  _text(_legal, 'Razón social', 'legal', caps: true, hint: 'Ej. Seguridad Ejemplo, S.A.'),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: _nit,
                      enabled: !_busy,
                      autocorrect: false,
                      textCapitalization: TextCapitalization.characters,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: 'NIT',
                        hintText: '1234567-8',
                        errorText: _errs['nit'],
                        helperText: nitWarn ? 'Revisa el NIT: el dígito verificador no cuadra.' : null,
                        helperStyle: const TextStyle(color: kWarn),
                      ),
                    ),
                  ),
                  _text(_rep, 'Representante legal', 'rep', caps: true),
                  Row(
                    children: [
                      Expanded(child: _text(_phone, 'Teléfono', 'phone', keyboard: TextInputType.phone)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _text(_email, 'Correo', 'email', keyboard: TextInputType.emailAddress),
                      ),
                    ],
                  ),
                  _text(_address, 'Dirección', 'address', caps: true),
                  Row(
                    children: [
                      Expanded(child: _text(_dept, 'Departamento', 'dept', caps: true)),
                      const SizedBox(width: 12),
                      Expanded(child: _text(_muni, 'Municipio', 'muni', caps: true)),
                    ],
                  ),
                ],
              ),
              FormCard(
                title: 'Licencia de operación (DIGESSP)',
                subtitle: 'Te avisamos antes de que venza.',
                children: [
                  if (lic != null && !_licRenew)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            daysFromToday(lic) < 0
                                ? 'Vencida desde ${fmtDate(lic)}'
                                : 'Vigente hasta ${fmtDate(lic)}',
                            style: TextStyle(
                              color: daysFromToday(lic) < 0
                                  ? AppColors.danger
                                  : (daysFromToday(lic) <= 60 ? kWarn : kOk),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                    _licRenew = true;
                                    _licNumber.clear();
                                    _licExpires.clear();
                                  }),
                          child: const Text('Renovar'),
                        ),
                      ],
                    ),
                  if (_licRenew)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Se guardará como licencia nueva; la anterior queda en el historial.',
                        style: TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(child: _text(_licNumber, 'Número o resolución', 'licNumber')),
                      const SizedBox(width: 12),
                      Expanded(child: _date2(_licExpires, 'Vence', 'licExpires')),
                    ],
                  ),
                ],
              ),
              FormCard(
                title: 'Suscripción a SaaS-DAG',
                subtitle: 'Solo tú la ves. Para cortar el acceso usa "Empresa activa" en la ficha.',
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: DropdownButtonFormField<String>(
                      // ignore: deprecated_member_use
                      value: _status,
                      decoration: const InputDecoration(labelText: 'Estado'),
                      items: [
                        for (final s in subscriptionStatuses)
                          DropdownMenuItem(value: s.$1, child: Text(s.$2)),
                      ],
                      onChanged: _busy ? null : (v) => setState(() => _status = v ?? 'trial'),
                    ),
                  ),
                  _text(_plan, 'Plan', 'plan', caps: true, hint: 'Ej. Básico, 20 guardas'),
                  Row(
                    children: [
                      Expanded(
                        child: _text(_fee, 'Cuota mensual (Q)', 'fee',
                            keyboard: const TextInputType.numberWithOptions(decimal: true)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _text(_billingDay, 'Día de cobro', 'billingDay', keyboard: TextInputType.number),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(child: _date2(_started, 'Inicio', 'started')),
                      const SizedBox(width: 12),
                      Expanded(child: _date2(_trialEnds, 'Fin de prueba', 'trialEnds')),
                    ],
                  ),
                  _text(_notes, 'Notas internas', 'notes', lines: 3),
                ],
              ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
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
                    : Text(_isNew ? 'Crear empresa' : 'Guardar cambios'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _text(
    TextEditingController x,
    String label,
    String key, {
    TextInputType? keyboard,
    bool caps = false,
    String? hint,
    int lines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: x,
        enabled: !_busy,
        keyboardType: lines > 1 ? TextInputType.multiline : keyboard,
        maxLines: lines,
        autocorrect: false,
        textCapitalization: caps ? TextCapitalization.words : TextCapitalization.none,
        decoration: InputDecoration(labelText: label, hintText: hint, errorText: _errs[key]),
      ),
    );
  }

  Widget _date2(TextEditingController x, String label, String key) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: x,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        inputFormatters: [DateTextFormatter()],
        decoration: InputDecoration(labelText: label, hintText: 'dd/mm/aaaa', errorText: _errs[key]),
      ),
    );
  }
}
