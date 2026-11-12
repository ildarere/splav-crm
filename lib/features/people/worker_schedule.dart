import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';
import '../../core/prototype.dart';
import '../trips/trip_format.dart';
import '../../app/sync_widgets.dart';

class WorkerSchedule extends StatefulWidget {
  const WorkerSchedule({
    super.key,
    required this.controller,
    required this.personId,
  });
  final Stage1Controller controller;
  final String personId;
  @override
  State<WorkerSchedule> createState() => _WorkerScheduleState();
}

class _WorkerScheduleState extends State<WorkerSchedule> {
  late DateTime _day = DateUtils.dateOnly(
    tz.TZDateTime.now(tz.getLocation('Europe/Saratov')),
  );
  Future<void> _save(PersonCard p, List<JsonMap> shifts) async {
    try {
      await widget.controller.savePerson(
        {...p.payload, 'work_schedule': shifts},
        teamId: p.teamId,
        previous: p,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось сохранить график. Проверьте изменения карточки.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _edit(PersonCard p, [JsonMap? old]) async {
    final result = await showDialog<JsonMap>(
      context: context,
      builder: (_) =>
          WorkerShiftEditor(person: p, initialDay: _day, shift: old),
    );
    if (result == null || !mounted) return;
    final current = widget.controller.peopleView.person(p.id);
    if (current == null) return;
    final start = DateTime.parse(result['starts_at'] as String),
        end = DateTime.parse(result['ends_at'] as String);
    final shifts = current.workSchedule
        .where((s) => s['id'] != result['id'])
        .toList();
    if ([...shifts, ...current.workAssignments].any(
      (s) =>
          DateTime.parse(s['starts_at'] as String).isBefore(end) &&
          start.isBefore(DateTime.parse(s['ends_at'] as String)),
    )) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Эта смена пересекается с другой сменой работника.'),
        ),
      );
      return;
    }
    await _save(current, [...shifts, result]);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final p = widget.controller.peopleView.person(widget.personId);
      if (p == null) {
        return const Scaffold(
          body: Center(child: Text('Карточка работника недоступна')),
        );
      }
      final editable =
          widget.controller.teams.any((t) => t.id == p.teamId && t.canCreate) &&
          !p.archived;
      final weekEnd = _day.add(const Duration(days: 7));
      final shifts =
          [...p.workSchedule, ...p.workAssignments]
              .where(
                (s) =>
                    DateTime.parse(s['starts_at'] as String).isBefore(
                      tz.TZDateTime(
                        tz.getLocation('Europe/Saratov'),
                        weekEnd.year,
                        weekEnd.month,
                        weekEnd.day,
                      ),
                    ) &&
                    DateTime.parse(s['ends_at'] as String).isAfter(
                      tz.TZDateTime(
                        tz.getLocation('Europe/Saratov'),
                        _day.year,
                        _day.month,
                        _day.day,
                      ),
                    ),
              )
              .toList()
            ..sort(
              (a, b) => (a['starts_at'] as String).compareTo(
                b['starts_at'] as String,
              ),
            );
      return Scaffold(
        appBar: AppBar(
          title: SyncPageTitle(
            title: 'График · ${p.name}',
            controller: widget.controller,
          ),
          actions: [RefreshAction(controller: widget.controller)],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Предыдущая неделя',
                        onPressed: () => setState(
                          () => _day = _day.subtract(const Duration(days: 7)),
                        ),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text(
                        '${_day.day}.${_day.month}.${_day.year} — ${weekEnd.subtract(const Duration(days: 1)).day}.${weekEnd.subtract(const Duration(days: 1)).month}',
                      ),
                      IconButton(
                        tooltip: 'Следующая неделя',
                        onPressed: () => setState(() => _day = weekEnd),
                        icon: const Icon(Icons.chevron_right),
                      ),
                      TextButton(
                        onPressed: () => setState(
                          () => _day = DateUtils.dateOnly(
                            tz.TZDateTime.now(tz.getLocation('Europe/Saratov')),
                          ),
                        ),
                        child: const Text('Сегодня'),
                      ),
                      FilledButton.icon(
                        onPressed: editable ? () => _edit(p) : null,
                        icon: const Icon(Icons.add),
                        label: const Text('Добавить смену'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Личный рабочий график. Смены сохраняются независимо от сплавов.',
                  ),
                  if (shifts.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('На выбранную неделю смен нет.'),
                    ),
                  for (final s in shifts)
                    Card(
                      child: ListTile(
                        isThreeLine: (s['notes'] as String? ?? '').isNotEmpty,
                        leading: const Icon(Icons.work_outline),
                        title: Text(
                          '${workerRoles[s['role']] ?? s['role']}${s['readonly'] == true ? ' · на сплаве' : ''}${s['paid'] == true ? ' · 0 · Оплачено' : ''}',
                        ),
                        subtitle: Text(
                          '${tripDate(DateTime.parse(s['starts_at'] as String), 'Europe/Saratov')} → ${tripDate(DateTime.parse(s['ends_at'] as String), 'Europe/Saratov')}${(s['notes'] as String? ?? '').isEmpty ? '' : '\n${s['notes']}'}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (s['readonly'] != true && editable)
                              IconButton(
                                tooltip: 'Изменить смену',
                                onPressed: s['readonly'] == true || !editable
                                    ? null
                                    : () => _edit(p, s),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                            if (s['readonly'] != true && editable)
                              IconButton(
                                tooltip: 'Удалить смену',
                                onPressed: () => _save(
                                  p,
                                  p.workSchedule
                                      .where((v) => v['id'] != s['id'])
                                      .toList(),
                                ),
                                icon: const Icon(Icons.delete_outline),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class WorkerShiftEditor extends StatefulWidget {
  const WorkerShiftEditor({
    super.key,
    required this.person,
    required this.initialDay,
    this.shift,
    this.roles,
    this.defaultStart,
    this.defaultEnd,
  });
  final PersonCard person;
  final DateTime initialDay;
  final JsonMap? shift;
  final List<String>? roles;
  final DateTime? defaultStart, defaultEnd;
  @override
  State<WorkerShiftEditor> createState() => _WorkerShiftEditorState();
}

class _WorkerShiftEditorState extends State<WorkerShiftEditor> {
  late final tz.Location _zone = tz.getLocation('Europe/Saratov');
  late DateTime _start = widget.shift == null
      ? widget.defaultStart ??
            tz.TZDateTime(
              _zone,
              widget.initialDay.year,
              widget.initialDay.month,
              widget.initialDay.day,
              8,
            )
      : DateTime.parse(widget.shift!['starts_at'] as String);
  late DateTime _end = widget.shift == null
      ? widget.defaultEnd ??
            tz.TZDateTime(
              _zone,
              widget.initialDay.year,
              widget.initialDay.month,
              widget.initialDay.day,
              19,
            )
      : DateTime.parse(widget.shift!['ends_at'] as String);
  late String? _role = _roles.contains(widget.shift?['role'])
      ? (widget.shift?['role'] as String)
      : _roles.firstOrNull;
  List<String> get _roles => widget.roles ?? widget.person.workRoles;
  late final _notes = TextEditingController(
    text: widget.shift?['notes'] as String? ?? '',
  );
  String? _error;
  late bool _paid = widget.shift?['paid'] == true;
  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pick(bool start) async {
    final current = tz.TZDateTime.from(start ? _start : _end, _zone);
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime(current.year, current.month, current.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
    );
    if (time == null || !mounted) return;
    setState(() {
      final value = tz.TZDateTime(
        _zone,
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      if (start) {
        _start = value;
      } else {
        _end = value;
      }
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.shift == null ? 'Новая смена' : 'Изменить смену'),
    scrollable: true,
    content: SizedBox(
      width: 500,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text(widget.person.name),
          DropdownButtonFormField<String>(
            initialValue: _role,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Работа *'),
            items: [
              for (final r in _roles)
                DropdownMenuItem(value: r, child: Text(workerRoles[r] ?? r)),
            ],
            onChanged: (v) => _role = v,
          ),
          OutlinedButton.icon(
            onPressed: () => _pick(true),
            icon: const Icon(Icons.event),
            label: Text('Начало · ${tripDate(_start, 'Europe/Saratov')}'),
          ),
          OutlinedButton.icon(
            onPressed: () => _pick(false),
            icon: const Icon(Icons.event),
            label: Text('Окончание · ${tripDate(_end, 'Europe/Saratov')}'),
          ),
          TextField(
            controller: _notes,
            decoration: const InputDecoration(labelText: 'Примечание'),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('0 · Оплачено'),
            value: _paid,
            onChanged: (value) => setState(() => _paid = value ?? false),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (_role == null || !_end.isAfter(_start)) {
            setState(
              () => _error = 'Выберите работу и окончание позже начала.',
            );
            return;
          }
          Navigator.pop(context, <String, dynamic>{
            'id': widget.shift?['id'] ?? const Uuid().v4(),
            'role': _role,
            'starts_at': _start.toUtc().toIso8601String(),
            'ends_at': _end.toUtc().toIso8601String(),
            'notes': _notes.text.trim(),
            'paid': _paid,
          });
        },
        child: const Text('Сохранить смену'),
      ),
    ],
  );
}
