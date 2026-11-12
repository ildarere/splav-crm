import '../../core/vest_sizes.dart';
import '../../core/input_formatters.dart';
import 'package:flutter/material.dart';
import '../../core/prototype.dart';

class PersonEditor extends StatefulWidget {
  const PersonEditor({
    super.key,
    required this.teams,
    required this.people,
    this.person,
    this.teamId,
    this.worker = false,
  });
  final List<TripTeam> teams;
  final List<PersonCard> people;
  final PersonCard? person;
  final String? teamId;
  final bool worker;
  @override
  State<PersonEditor> createState() => _PersonEditorState();
}

class _PersonEditorState extends State<PersonEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name, _phone, _birth, _notes;
  late String _teamId;
  final _parameters = <String, TextEditingController>{};
  late final bool _worker = widget.person?.isWorker ?? widget.worker;
  late final Set<String> _roles = {...?widget.person?.workRoles};
  bool _separate = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final person = widget.person;
    _teamId = person?.teamId ?? widget.teamId ?? widget.teams.first.id;
    _name = TextEditingController(text: person?.name ?? '');
    _phone = TextEditingController(text: person?.phone ?? '');
    final date = DateTime.tryParse(person?.birthDate ?? '');
    _birth = TextEditingController(
      text: date == null
          ? ''
          : '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}',
    );
    _notes = TextEditingController(text: person?.notes ?? '');
    for (final key in [
      'clothing_size',
      'height_cm',
      'weight_kg',
      'age_years',
    ]) {
      _parameters[key] = TextEditingController(
        text: (person?.data['parameters'] as Map?)?[key]?.toString() ?? '',
      );
    }
  }

  @override
  void dispose() {
    for (final field in [
      _name,
      _phone,
      _birth,
      _notes,
      ..._parameters.values,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  DateTime? _date() {
    final match = RegExp(
      r'^(\d{2})\.(\d{2})\.(\d{4})$',
    ).firstMatch(_birth.text.trim());
    if (match == null) return null;
    final d = int.parse(match[1]!),
        m = int.parse(match[2]!),
        y = int.parse(match[3]!);
    final date = DateTime.utc(y, m, d);
    return date.year == y && date.month == m && date.day == d ? date : null;
  }

  List<PersonCard> get _duplicates {
    final name = _name.text.trim().toLowerCase().replaceAll('ё', 'е');
    final phone = normalizedPhone(_phone.text);
    return widget.people
        .where(
          (p) =>
              p.id != widget.person?.id &&
              p.teamId == _teamId &&
              p.mergedInto == null &&
              ((name.isNotEmpty &&
                      p.name.toLowerCase().replaceAll('ё', 'е') == name) ||
                  (phone.isNotEmpty && normalizedPhone(p.phone) == phone)),
        )
        .toList();
  }

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (widget.person == null && _duplicates.isNotEmpty && !_separate) {
      setState(
        () => _error =
            'Выберите существующую карточку или подтвердите создание отдельной.',
      );
      return;
    }
    if (_worker && _roles.isEmpty) {
      setState(() => _error = 'Укажите специализацию работника.');
      return;
    }
    Navigator.pop(context, <String, dynamic>{
      'is_worker': _worker,
      'work_roles': _roles.toList(),
      'work_schedule': widget.person?.workSchedule ?? [],
      'parameters': normalizedParameters({
        for (final e in _parameters.entries)
          if (e.value.text.trim().isNotEmpty)
            e.key: e.key == 'clothing_size'
                ? e.value.text.trim()
                : num.parse(e.value.text.replaceAll(',', '.')),
      }),
      'team_id': _teamId,
      'name': _name.text.trim(),
      'phone': _phone.text.trim(),
      'birth_date': _birth.text.trim().isEmpty
          ? null
          : _date()!.toIso8601String().substring(0, 10),
      'notes': _notes.text.trim(),
      'archived': widget.person?.archived ?? false,
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      _worker
          ? (widget.person == null ? 'Новый работник' : 'Карточка работника')
          : widget.person == null
          ? 'Новый человек'
          : 'Карточка человека',
    ),
    scrollable: true,
    content: SizedBox(
      width: 520,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              maxLength: 100,
              decoration: const InputDecoration(
                counterText: '',
                labelText: 'Имя и фамилия *',
              ),
              onChanged: (_) => setState(() => _separate = false),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Введите имя' : null,
            ),
            TextFormField(
              controller: _phone,
              inputFormatters: [DigitMask('+7 (###) ###-##-##')],
              keyboardType: TextInputType.phone,
              maxLength: 100,
              decoration: const InputDecoration(
                counterText: '',
                labelText: 'Телефон',
                helperText: 'Можно указать общий семейный номер',
              ),
              onChanged: (_) => setState(() => _separate = false),
            ),
            TextFormField(
              controller: _birth,
              keyboardType: TextInputType.number,
              inputFormatters: [DigitMask('##.##.####')],
              decoration: const InputDecoration(
                counterText: '',
                labelText: 'Дата рождения',
                hintText: 'ДД.ММ.ГГГГ',
              ),
              validator: (_) => _birth.text.trim().isNotEmpty && _date() == null
                  ? 'Введите существующую дату в формате ДД.ММ.ГГГГ'
                  : null,
            ),
            if (_worker)
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final e in workerRoles.entries)
                    FilterChip(
                      label: Text(e.value),
                      selected: _roles.contains(e.key),
                      onSelected: (v) => setState(
                        () => v ? _roles.add(e.key) : _roles.remove(e.key),
                      ),
                    ),
                ],
              ),
            if (!_worker)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in {
                    'clothing_size': 'Размер жилета',
                    'height_cm': 'Рост, см',
                    'weight_kg': 'Вес, кг',
                    'age_years': 'Возраст',
                  }.entries)
                    SizedBox(
                      width: 108,
                      child: TextFormField(
                        controller: _parameters[e.key],
                        keyboardType: e.key == 'clothing_size'
                            ? TextInputType.text
                            : const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                        decoration: InputDecoration(
                          labelText: e.value,
                          isDense: true,
                        ),
                        validator: (v) {
                          if ((v ?? '').trim().isEmpty ||
                              e.key == 'clothing_size') {
                            return null;
                          }
                          final n = num.tryParse(v!.replaceAll(',', '.'));
                          return n == null ||
                                  !n.isFinite ||
                                  n < 0 ||
                                  n > (e.key == 'age_years' ? 150 : 300) ||
                                  (e.key == 'age_years' && n != n.round())
                              ? 'Проверьте'
                              : null;
                        },
                      ),
                    ),
                ],
              ),
            TextFormField(
              controller: _notes,
              maxLines: 3,
              maxLength: 2000,
              decoration: const InputDecoration(
                counterText: '',
                labelText: 'Примечание',
              ),
            ),
            if (_duplicates.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 8,
                    children: [
                      const Text('Есть похожие карточки'),
                      for (final person in _duplicates.take(5))
                        OutlinedButton(
                          onPressed: () => Navigator.pop(
                            context,
                            <String, dynamic>{'use_existing': person.id},
                          ),
                          child: Text(
                            '${person.name}${person.phone.isEmpty ? '' : ' · ${person.phone}'}${person.archived ? ' · в архиве' : ''}',
                          ),
                        ),
                      if (widget.person == null)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _separate,
                          onChanged: (v) => setState(() => _separate = v!),
                          title: const Text('Проверено, это другой человек'),
                        ),
                    ],
                  ),
                ),
              ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
