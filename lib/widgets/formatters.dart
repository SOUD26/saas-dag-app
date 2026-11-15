import 'package:flutter/services.dart';

String _digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

/// Escribe "15031990" y queda "15/03/1990".
class DateTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = _digits(newValue.text);
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
class DpiTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = _digits(newValue.text);
    final b = StringBuffer();
    for (var i = 0; i < digits.length && i < 13; i++) {
      if (i == 4 || i == 9) b.write(' ');
      b.write(digits[i]);
    }
    final t = b.toString();
    return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }
}
