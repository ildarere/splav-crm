import 'package:flutter/material.dart';

class SuggestedParticipant {
  SuggestedParticipant(this.name, this.parameters, this.source);
  String name;
  final Map<String, dynamic> parameters;
  final String source;
}

List<SuggestedParticipant> parseCompany(String text) {
  final result = <SuggestedParticipant>[];
  for (var line in text.split(RegExp(r'[\r\n;]+'))) {
    line = line.trim();
    if (line.isEmpty) continue;
    final start =
        RegExp(
          r'\d|\s[-–—]\s|\s(?:XXXL|XXL|XL|XS|S|M|L|М)\s*$',
        ).firstMatch(line)?.start ??
        line.length;
    var name = line
        .substring(0, start)
        .replaceAll(RegExp(r'[\s,\-–—:]+$'), '')
        .replaceFirst(RegExp(r'^\s*[•*]\s*'), '')
        .trim();
    var tail = line.substring(start);
    // Latin and Cyrillic letter sizes may follow a name without a dash.
    final size = RegExp(
      r'(?:^|[\s,\-–—])((?:XXXL|XXL|XL|XS|S|M|L|ХХХL|ХХL|ХL|М|Л|С))(?:$|[\s,])',
      caseSensitive: false,
    ).firstMatch(tail);
    final p = <String, dynamic>{};
    if (size != null) {
      p['clothing_size'] = size[1]!
          .toUpperCase()
          .replaceAll('М', 'M')
          .replaceAll('Х', 'X')
          .replaceAll('Л', 'L')
          .replaceAll('С', 'S');
    }
    void take(String key, String pattern) {
      final m = RegExp(pattern, caseSensitive: false).firstMatch(tail);
      if (m != null) {
        p[key] = key == 'clothing_size'
            ? m[1]!
            : num.parse(m[1]!.replaceAll(',', '.'));
        tail = tail.replaceRange(m.start, m.end, ' ');
      }
    }

    take('age_years', r'(\d{1,3})\s*(?:лет|года?|л\.)');
    take('weight_kg', r'(\d{1,3}(?:[.,]\d+)?)\s*(?:кг|kg)');
    take('height_cm', r'(\d{2,3})\s*(?:см|cm)');
    take('clothing_size', r'(\d{2,3})\s*(?:р(?:азмер)?\.?)(?=\s|,|$)');
    final nums = RegExp(
      r'\b\d{2,3}\b',
    ).allMatches(tail).map((m) => int.parse(m[0]!)).toList();
    for (final n in nums) {
      if (n >= 100 && n <= 230 && !p.containsKey('height_cm')) {
        p['height_cm'] = n;
      } else if (n >= 20 && n <= 80 && !p.containsKey('clothing_size')) {
        p['clothing_size'] = '$n';
      }
    }
    if (name.isEmpty) name = line;
    result.add(SuggestedParticipant(name, p, line));
  }
  return result;
}

Future<List<SuggestedParticipant>?> previewCompany(
  BuildContext context,
  String text,
) {
  final rows = parseCompany(text);
  final form = GlobalKey<FormState>();
  return showDialog<List<SuggestedParticipant>>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Добавить компанию · ${rows.length} чел.'),
      scrollable: true,
      content: Form(
        key: form,
        child: SizedBox(
          width: 850,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Проверьте распознанные данные. Пустые поля можно заполнить позже.',
              ),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      SizedBox(
                        width: 270,
                        child: TextFormField(
                          initialValue: row.name,
                          validator: (v) =>
                              (v ?? '').trim().isEmpty ? 'Укажите имя' : null,
                          decoration: const InputDecoration(
                            labelText: 'ФИО *',
                            isDense: true,
                          ),
                          onChanged: (v) => row.name = v,
                        ),
                      ),
                      for (final field in {
                        'clothing_size': 'Размер',
                        'height_cm': 'Рост, см',
                        'weight_kg': 'Вес, кг',
                        'age_years': 'Возраст',
                      }.entries)
                        SizedBox(
                          width: 105,
                          child: TextFormField(
                            initialValue:
                                row.parameters[field.key]?.toString() ?? '',
                            validator: (v) {
                              if ((v ?? '').trim().isEmpty ||
                                  field.key == 'clothing_size') {
                                return null;
                              }
                              final n = num.tryParse(v!.replaceAll(',', '.'));
                              return n == null ||
                                      !n.isFinite ||
                                      n < 0 ||
                                      n >
                                          (field.key == 'age_years'
                                              ? 150
                                              : 300) ||
                                      (field.key == 'age_years' &&
                                          n != n.round())
                                  ? 'Проверьте'
                                  : null;
                            },
                            keyboardType: field.key == 'clothing_size'
                                ? TextInputType.text
                                : TextInputType.number,
                            decoration: InputDecoration(
                              labelText: field.value,
                              isDense: true,
                            ),
                            onChanged: (v) {
                              if (v.trim().isEmpty) {
                                row.parameters.remove(field.key);
                              } else {
                                row.parameters[field.key] =
                                    field.key == 'clothing_size'
                                    ? v.trim()
                                    : num.tryParse(v.replaceAll(',', '.'));
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: rows.isEmpty
              ? null
              : () {
                  if (!(form.currentState?.validate() ?? false)) return;
                  Navigator.pop(context, rows);
                },
          child: const Text('Добавить в компанию'),
        ),
      ],
    ),
  );
}
