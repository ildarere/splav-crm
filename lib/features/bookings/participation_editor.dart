import '../../core/vest_sizes.dart';
import 'package:flutter/material.dart';
import '../../core/prototype.dart';

class ParticipationEditor extends StatefulWidget {
  const ParticipationEditor({
    super.key,
    required this.name,
    this.role = 'client',
    this.parameters = const {},
  });
  final String name;
  final String role;
  final JsonMap parameters;
  @override
  State<ParticipationEditor> createState() => _ParticipationEditorState();
}

class _ParticipationEditorState extends State<ParticipationEditor> {
  final _form = GlobalKey<FormState>();
  final _fields = <String, TextEditingController>{};
  static const _labels = {
    'height_cm': 'Рост, см',
    'weight_kg': 'Вес, кг',
    'age_years': 'Возраст на выезд, лет',
    'clothing_size': 'Размер одежды',
    'food_notes': 'Пожелания к питанию',
    'notes': 'Примечание к участию',
  };
  @override
  void initState() {
    super.initState();
    for (final key in _labels.keys) {
      _fields[key] = TextEditingController(
        text: widget.parameters[key]?.toString() ?? '',
      );
    }
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final params = <String, dynamic>{};
    for (final entry in _fields.entries) {
      final value = entry.value.text.trim();
      if (value.isEmpty) continue;
      params[entry.key] =
          ['height_cm', 'weight_kg', 'age_years'].contains(entry.key)
          ? num.parse(value.replaceAll(',', '.'))
          : value;
    }
    Navigator.pop(context, <String, dynamic>{
      'role': widget.role,
      'parameters': normalizedParameters(params),
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.name),
    scrollable: true,
    content: SizedBox(
      width: 520,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            const Text('Эти параметры сохраняются для конкретного выезда.'),
            for (final entry in _labels.entries)
              TextFormField(
                controller: _fields[entry.key],
                keyboardType:
                    ['height_cm', 'weight_kg', 'age_years'].contains(entry.key)
                    ? const TextInputType.numberWithOptions(decimal: true)
                    : TextInputType.text,
                maxLength: ['food_notes', 'notes'].contains(entry.key)
                    ? 1000
                    : 30,
                maxLines: ['food_notes', 'notes'].contains(entry.key) ? 3 : 1,
                decoration: InputDecoration(
                  counterText: '',
                  labelText: entry.value,
                ),
                validator: (value) {
                  if (![
                        'height_cm',
                        'weight_kg',
                        'age_years',
                      ].contains(entry.key) ||
                      (value ?? '').trim().isEmpty) {
                    return null;
                  }
                  final number = num.tryParse(value!.replaceAll(',', '.'));
                  if (number == null ||
                      !number.isFinite ||
                      number < 0 ||
                      number > 1000 ||
                      (entry.key == 'age_years' &&
                          (number > 150 || number != number.truncate()))) {
                    return 'Проверьте число';
                  }
                  return null;
                },
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
      FilledButton(onPressed: _save, child: const Text('Сохранить')),
    ],
  );
}
