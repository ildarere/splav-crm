import '../../core/input_formatters.dart';
import 'package:flutter/services.dart';
import 'company_import.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../core/prototype.dart';
import '../people/person_editor.dart';
import 'participation_editor.dart';

class BookingFormResult {
  const BookingFormResult(this.payload, this.newPeople);
  final JsonMap payload;
  final List<JsonMap> newPeople;
}

class BookingEditor extends StatefulWidget {
  const BookingEditor({super.key, required this.controller, this.booking});
  final Stage1Controller controller;
  final Booking? booking;
  @override
  State<BookingEditor> createState() => _BookingEditorState();
}

class _BookingEditorState extends State<BookingEditor> {
  final _form = GlobalKey<FormState>();
  final _members = <JsonMap>[];
  final _newPeople = <JsonMap>[];
  late final TextEditingController _contact, _phone, _notes;
  String? _contactId, _error;
  @override
  void initState() {
    super.initState();
    final b = widget.booking;
    _contact = TextEditingController(text: b?.contactName ?? '');
    _phone = TextEditingController(text: b?.phone ?? '');
    _notes = TextEditingController(text: b?.notes ?? '');
    _contactId = b?.contactPersonId;
  }

  @override
  void dispose() {
    for (final field in [_contact, _phone, _notes]) {
      field.dispose();
    }
    super.dispose();
  }

  List<PersonCard> get _people => [
    ...widget.controller.peopleView.people,
    ..._newPeople.map(
      (p) => PersonCard({
        ...p,
        'team_id': widget.controller.selectedTrip!.teamId,
        'version': 1,
      }),
    ),
  ];
  PersonCard? _person(String id) =>
      _people.where((p) => p.id == id).firstOrNull;

  Future<PersonCard?> _choose({bool newPerson = false}) async {
    final teamId = widget.controller.selectedTrip!.teamId;
    if (newPerson) {
      final result = await showDialog<JsonMap>(
        context: context,
        builder: (_) => PersonEditor(
          teams: widget.controller.teams,
          people: _people,
          teamId: teamId,
        ),
      );
      if (result == null) return null;
      if (result['use_existing'] case final String id) return _person(id);
      final person = {...result, 'id': const Uuid().v4(), 'team_id': teamId};
      setState(() => _newPeople.add(person));
      return _person(person['id'] as String);
    }
    return showDialog<PersonCard>(
      context: context,
      builder: (_) => _PersonPicker(
        people: _people
            .where(
              (p) => p.teamId == teamId && !p.archived && p.mergedInto == null,
            )
            .toList(),
      ),
    );
  }

  Future<void> _add(bool create) async {
    final person = await _choose(newPerson: create);
    if (person == null || !mounted) return;
    if (person.archived ||
        _members.any((m) => m['person_id'] == person.id) ||
        widget.controller.peopleView.participations.any(
          (p) => p.personId == person.id,
        )) {
      setState(
        () => _error =
            'Человек уже есть в выезде или его карточка в архиве. Существующее участие можно восстановить в составе.',
      );
      return;
    }
    final history = await widget.controller.database.personHistory(person.id);
    if (!mounted) return;
    final parameters = <String, dynamic>{
      ...?history.firstOrNull?['parameters'] as JsonMap?,
      ...?person.data['parameters'] as JsonMap?,
    };
    setState(() {
      _members.add({
        'id': const Uuid().v4(),
        'person_id': person.id,
        'role': 'client',
        'parameters': parameters,
      });
      if (_contact.text.trim().isEmpty) {
        _contact.text = person.name;
        _phone.text = person.phone;
        _contactId = person.id;
      }
      _error = null;
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    if (data?.text?.trim().isNotEmpty != true) {
      setState(
        () => _error = 'В буфере нет текста. Скопируйте список участников.',
      );
      return;
    }
    final rows = await previewCompany(context, data!.text!);
    if (rows == null || !mounted) return;
    setState(() {
      for (final row in rows) {
        final id = const Uuid().v4();
        _newPeople.add({
          'id': id,
          'name': row.name.trim(),
          'phone': '',
          'notes': '',
          'team_id': widget.controller.selectedTrip!.teamId,
        });
        _members.add({
          'id': const Uuid().v4(),
          'person_id': id,
          'role': 'client',
          'parameters': row.parameters,
        });
      }
      if (_contact.text.trim().isEmpty && rows.isNotEmpty) {
        _contact.text = rows.first.name;
        _contactId = _members.first['person_id'] as String;
      }
      _error = null;
    });
  }

  Future<void> _parameters(JsonMap member) async {
    final result = await showDialog<JsonMap>(
      context: context,
      builder: (_) => ParticipationEditor(
        name: _person(member['person_id'] as String)?.name ?? 'Участник',
        role: member['role'] as String,
        parameters: Map<String, dynamic>.from(member['parameters'] as Map),
      ),
    );
    if (result != null) setState(() => member.addAll(result));
  }

  Future<void> _contactPerson() async {
    final person = await _choose();
    if (person != null) {
      setState(() {
        _contactId = person.id;
        _contact.text = person.name;
        _phone.text = person.phone;
      });
    }
  }

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (widget.booking == null && _members.isEmpty) {
      setState(() => _error = 'Добавьте хотя бы одного участника.');
      return;
    }
    final references = {
      for (final member in _members) member['person_id'],
      if (_contactId != null) _contactId,
    };
    Navigator.pop(
      context,
      BookingFormResult({
        'contact_person_id': _contactId,
        'contact_name': _contact.text.trim(),
        'phone': _phone.text.trim(),
        'notes': _notes.text.trim(),
        'members': _members,
      }, _newPeople.where((p) => references.contains(p['id'])).toList()),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.booking == null ? 'Новая компания' : 'Изменить компанию',
    ),
    scrollable: true,
    content: SizedBox(
      width: 760,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _paste,
              icon: const Icon(Icons.content_paste_go),
              label: const Text('Быстро добавить из буфера'),
            ),
            OutlinedButton.icon(
              onPressed: _contactPerson,
              icon: const Icon(Icons.contact_page_outlined),
              label: const Text('Выбрать контакт из людей'),
            ),
            TextFormField(
              controller: _contact,
              maxLength: 150,
              decoration: const InputDecoration(
                counterText: '',
                labelText: 'Контактное лицо *',
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Укажите контактное лицо' : null,
            ),
            TextFormField(
              controller: _phone,
              inputFormatters: [DigitMask('+7 (###) ###-##-##')],
              maxLength: 100,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                counterText: '',
                labelText: 'Контактный телефон',
              ),
            ),
            TextFormField(
              controller: _notes,
              maxLength: 2000,
              maxLines: 1,
              decoration: const InputDecoration(
                counterText: '',
                labelText: 'Примечание к компании',
              ),
            ),
            if (widget.booking != null) ...[
              const Text('Участники компании'),
              for (final member
                  in widget.controller.peopleView.participations.where(
                    (p) => p.bookingId == widget.booking!.id,
                  ))
                Text(
                  '${_person(member.personId)?.name ?? 'Участник'} · ${participationLabel(member.status)}',
                ),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _add(false),
                  icon: const Icon(Icons.search),
                  label: const Text('Добавить из людей'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _add(true),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Новый участник'),
                ),
              ],
            ),
            for (final member in _members)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  _person(member['person_id'] as String)?.name ?? 'Участник',
                ),
                subtitle: Text(
                  (member['parameters'] as Map).entries
                      .map(
                        (e) =>
                            '${{'clothing_size': 'Размер', 'height_cm': 'Рост', 'weight_kg': 'Вес', 'age_years': 'Возраст'}[e.key] ?? e.key}: ${e.value}',
                      )
                      .join(' · '),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Изменить параметры',
                      onPressed: () => _parameters(member),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: 'Удалить',
                      onPressed: () => setState(() => _members.remove(member)),
                      icon: const Icon(Icons.close),
                    ),
                  ],
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
      FilledButton(onPressed: _save, child: const Text('Сохранить компанию')),
    ],
  );
}

class _PersonPicker extends StatefulWidget {
  const _PersonPicker({required this.people});
  final List<PersonCard> people;
  @override
  State<_PersonPicker> createState() => _PersonPickerState();
}

class _PersonPickerState extends State<_PersonPicker> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final people = widget.people
        .where(
          (p) =>
              p.name.toLowerCase().contains(_query.toLowerCase()) ||
              (normalizedPhone(_query).isNotEmpty &&
                  normalizedPhone(p.phone).contains(normalizedPhone(_query))),
        )
        .toList();
    return AlertDialog(
      title: const Text('Выбрать человека'),
      content: SizedBox(
        width: 540,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                counterText: '',
                labelText: 'Имя или телефон',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: people.isEmpty
                  ? const Center(child: Text('Подходящих карточек нет.'))
                  : ListView.builder(
                      itemCount: people.length,
                      itemBuilder: (context, index) {
                        final person = people[index];
                        return ListTile(
                          title: Text(person.name),
                          subtitle: person.phone.isEmpty
                              ? null
                              : Text(person.phone),
                          onTap: () => Navigator.pop(context, person),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
      ],
    );
  }
}
