import 'dart:math';

import '../admin/staff_file.dart' show dpiLooksValid;

/// Id único creado en el teléfono (UUID v4). Sirve para que un registro que se envía dos veces
/// (por ejemplo, al volver la señal) no se duplique en el servidor.
String newId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

// ───────────────────────── Placas de Guatemala ─────────────────────────
// Formato: prefijo (P particular, M moto, C comercial, A alquiler, TC camión, etc.) + 3 números + 3 letras.

const _platePrefixes = 'TRC|TC|TE|CD|CC|MI|DIS|P|M|C|A|U|O';

String _asDigits(String s) => s
    .replaceAll('O', '0')
    .replaceAll('Q', '0')
    .replaceAll('D', '0')
    .replaceAll('I', '1')
    .replaceAll('L', '1')
    .replaceAll('Z', '2')
    .replaceAll('S', '5')
    .replaceAll('B', '8')
    .replaceAll('G', '6');

String _asLetters(String s) => s
    .replaceAll('0', 'O')
    .replaceAll('1', 'I')
    .replaceAll('2', 'Z')
    .replaceAll('5', 'S')
    .replaceAll('8', 'B')
    .replaceAll('6', 'G');

/// Busca una placa en el texto leído de la foto. Devuelve solo letras y números ("P123ABC").
String? findPlate(String raw, {bool moto = false}) {
  final t = raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9\n]'), ' ');
  final full = RegExp('\\b($_platePrefixes)\\s*([0-9A-Z]{3})\\s*([0-9A-Z]{3})\\b');
  for (final m in full.allMatches(t)) {
    final d = _asDigits(m.group(2)!);
    final l = _asLetters(m.group(3)!);
    if (RegExp(r'^\d{3}$').hasMatch(d) && RegExp(r'^[A-Z]{3}$').hasMatch(l)) {
      return '${m.group(1)}$d$l';
    }
  }
  // Sin prefijo legible: 3 números + 3 letras.
  final bare = RegExp(r'\b([0-9]{3})\s*([A-Z]{3})\b');
  final m = bare.firstMatch(t);
  if (m != null) return '${moto ? 'M' : 'P'}${m.group(1)}${m.group(2)}';
  return null;
}

/// "P123ABC" -> "P-123ABC"
String fmtPlate(String? p) {
  final s = (p ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  final m = RegExp(r'^([A-Z]{1,3})(\d{3}[A-Z]{3})$').firstMatch(s);
  return m == null ? s : '${m.group(1)}-${m.group(2)}';
}

// ───────────────────────── DPI y licencia ─────────────────────────

class IdRead {
  const IdRead({this.cui, this.cuiChecked = false, this.name, this.license = false});
  final String? cui; // 13 dígitos
  final bool cuiChecked; // pasó el dígito verificador
  final String? name;
  final bool license; // la foto parece licencia de conducir
}

const _labelWords = [
  'REPUBLICA', 'REPÚBLICA', 'GUATEMALA', 'DOCUMENTO', 'PERSONAL', 'IDENTIFICACION', 'IDENTIFICACIÓN', 'RENAP',
  'NOMBRE', 'APELLIDO', 'SEXO', 'FECHA', 'NACIMIENTO', 'LUGAR', 'VECINDAD', 'ESTADO', 'CIVIL', 'NACIONALIDAD',
  'LICENCIA', 'CONDUCIR', 'TIPO', 'DEPARTAMENTO', 'MUNICIPIO', 'EMISION', 'EMISIÓN', 'VENCE', 'VENCIMIENTO',
  'CUI', 'DPI', 'MASCULINO', 'FEMENINO', 'GUATEMALTECO', 'GUATEMALTECA', 'TRANSITO', 'TRÁNSITO', 'SAT',
];

bool _looksLikeName(String line) {
  final s = line.trim();
  if (s.length < 3 || s.length > 60) return false;
  if (!RegExp(r'^[A-Za-zÁÉÍÓÚÜÑáéíóúüñ ]+$').hasMatch(s)) return false;
  final up = s.toUpperCase();
  return !_labelWords.any((w) => up.contains(w));
}

String _title(String s) => s
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .where((p) => p.isNotEmpty)
    .map((p) => const {'de', 'del', 'la', 'las', 'los', 'y'}.contains(p) ? p : p[0].toUpperCase() + p.substring(1))
    .join(' ');

/// Lee el número de DPI/CUI (13 dígitos) y, si aparece rotulado, el nombre.
IdRead readId(String raw) {
  final up = raw.toUpperCase();
  final license = up.contains('LICENCIA') || up.contains('CONDUCIR');
  final lines = raw.split('\n');

  String? cui;
  var checked = false;
  String? unchecked;
  for (final source in [...lines, raw.replaceAll('\n', ' ')]) {
    final groups = RegExp(r'\d+').allMatches(source).map((m) => m.group(0)!).toList();
    for (var i = 0; i < groups.length && cui == null; i++) {
      var acc = '';
      for (var j = i; j < groups.length; j++) {
        acc += groups[j];
        if (acc.length == 13) {
          if (dpiLooksValid(acc)) {
            cui = acc;
            checked = true;
          } else {
            unchecked ??= acc;
          }
          break;
        }
        if (acc.length > 13) break;
      }
    }
    if (cui != null) break;
  }
  cui ??= unchecked;

  String? names;
  String? surnames;
  for (var i = 0; i < lines.length - 1; i++) {
    final l = lines[i].toUpperCase();
    final next = lines[i + 1];
    if (names == null && l.contains('NOMBRE') && _looksLikeName(next)) names = next.trim();
    if (surnames == null && l.contains('APELLIDO') && _looksLikeName(next)) surnames = next.trim();
  }
  final name = [names, surnames].whereType<String>().join(' ').trim();
  return IdRead(cui: cui, cuiChecked: checked, name: name.isEmpty ? null : _title(name), license: license);
}
