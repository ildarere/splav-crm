import 'package:flutter/services.dart';

class DigitMask extends TextInputFormatter {
  DigitMask(this.pattern);
  final String pattern;
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (pattern.startsWith('+7') &&
        (newValue.text.startsWith('+7') ||
            (digits.length == 11 &&
                (digits.startsWith('7') || digits.startsWith('8'))))) {
      digits = digits.substring(1);
    }
    final out = StringBuffer();
    var at = 0;
    var caret = 0;
    final before = newValue.text
        .substring(
          0,
          newValue.selection.extentOffset.clamp(0, newValue.text.length),
        )
        .replaceAll(RegExp(r'\D'), '')
        .length;
    for (final c in pattern.split('')) {
      if (at >= digits.length) break;
      if (c == '#') {
        out.write(digits[at++]);
        if (at <= before) caret = out.length;
      } else {
        out.write(c);
      }
    }
    return TextEditingValue(
      text: out.toString(),
      selection: TextSelection.collapsed(
        offset: newValue.selection.extentOffset == newValue.text.length
            ? out.length
            : caret,
      ),
    );
  }
}
