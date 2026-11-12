import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../app/sync_widgets.dart';
import '../../core/prototype.dart';
import '../trips/trip_format.dart';
import 'people_conflicts.dart';
import 'worker_schedule.dart';

class WorkScheduleScreen extends StatefulWidget {
  const WorkScheduleScreen({
    super.key,
    required this.controller,
    this.initialTrip,
  });

  final Stage1Controller controller;
  final Trip? initialTrip;

  @override
  State<WorkScheduleScreen> createState() => _WorkScheduleScreenState();
}

class _WorkScheduleScreenState extends State<WorkScheduleScreen> {
  static const _zoneName = 'Europe/Saratov';
  static const _weekdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
  static const _dayWidth = 174.0;

  final _header = ScrollController();
  final _body = ScrollController();
  late final _zone = tz.getLocation(_zoneName);
  late DateTime _anchor = widget.initialTrip == null
      ? tz.TZDateTime.now(_zone)
      : tz.TZDateTime.from(widget.initialTrip!.startsAt, _zone);
  bool _month = false;
  late String? _teamId = widget.initialTrip?.teamId;
  bool _scrolling = false;

  Stage1Controller get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _header.addListener(_syncHeader);
    _body.addListener(_syncBody);
  }

  @override
  void dispose() {
    _header.dispose();
    _body.dispose();
    super.dispose();
  }

  void _syncHeader() => _syncScroll(_header, _body);
  void _syncBody() => _syncScroll(_body, _header);

  void _syncScroll(ScrollController source, ScrollController target) {
    if (_scrolling ||
        !target.hasClients ||
        !target.position.hasContentDimensions) {
      return;
    }
    _scrolling = true;
    target.jumpTo(source.offset.clamp(0.0, target.position.maxScrollExtent));
    _scrolling = false;
  }

  DateTime _day(DateTime date, int offset) =>
      tz.TZDateTime(_zone, date.year, date.month, date.day + offset);

  DateTime _monday(DateTime date) => _day(date, 1 - date.weekday);

  void _movePeriod(int direction) => setState(() {
    _anchor = _month
        ? tz.TZDateTime(_zone, _anchor.year, _anchor.month + direction)
        : _day(_anchor, direction * 7);
  });

  String _dateLabel(DateTime day) =>
      '${_weekdays[day.weekday - 1]}, ${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}';

  bool _overlaps(DateTime start, DateTime end, DateTime day) =>
      start.isBefore(_day(day, 1)) && day.isBefore(end);

  bool _editableTrip(Trip trip) =>
      trip.version > 0 &&
      !['draft', 'completed', 'cancelled'].contains(trip.status);

  List<String> _roles(PersonCard person, bool kitchen) => person.workRoles
      .where(
        (role) => kitchen ? role == 'trip_cook' : escortRoles.contains(role),
      )
      .toList();

  List<JsonMap> _assignments(PersonCard person) {
    final duties = {for (final row in person.workAssignments) row['id']: row};
    final conflicts = <JsonMap>[];
    for (final command in _c.peopleView.commands.where(
      (c) =>
          c.teamId == person.teamId &&
          c.kind == 'ops_reservation' &&
          c.payload['kind'] == 'duty' &&
          person.workResourceId != null &&
          c.payload['resource_id'] == person.workResourceId,
    )) {
      final trip = _c.trips.where((t) => t.id == command.tripId).firstOrNull;
      final row = {
        ...command.payload,
        'trip_id': command.tripId,
        'title': trip?.title,
        'readonly': true,
        'command': command,
        'busy_start': DateTime.parse(command.payload['starts_at'] as String)
            .subtract(
              Duration(minutes: command.payload['prep_minutes'] as int? ?? 0),
            )
            .toIso8601String(),
        'busy_end': DateTime.parse(command.payload['ends_at'] as String)
            .add(
              Duration(minutes: command.payload['return_minutes'] as int? ?? 0),
            )
            .toIso8601String(),
      };
      if (command.error == null) {
        duties[row['id']] = row;
      } else {
        conflicts.add(row);
      }
    }
    return [...person.workSchedule, ...duties.values, ...conflicts]..sort(
      (a, b) => DateTime.parse(
        a['starts_at'] as String,
      ).compareTo(DateTime.parse(b['starts_at'] as String)),
    );
  }

  String _assignmentLabel(JsonMap row, {bool showPayment = true}) {
    final role = workerRoles[row['role']] ?? 'Смена';
    final title = row['title'] as String?;
    if (row['command'] case final PeopleCommand command) {
      if (command.error != null) return '$role · конфликт';
      if (row['active'] == false) return '$role · снятие';
    }
    return [
      role,
      ?title,
      if (showPayment && row['paid'] == true) '0 · Оплачено',
    ].join(' · ');
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _save(
    PersonCard person,
    JsonMap? old,
    JsonMap? change,
    Trip? trip,
  ) async {
    try {
      final current = _c.peopleView.person(person.id);
      if (current == null || current.archived || !current.isWorker) {
        _showError('Карточка работника изменилась. Откройте ячейку заново.');
        return;
      }
      if (trip == null && current.version != person.version) {
        _showError('График работника изменился. Откройте ячейку заново.');
        return;
      }
      if (change != null) {
        final start = DateTime.parse(
          change['starts_at'] as String,
        ).subtract(Duration(minutes: old?['prep_minutes'] as int? ?? 0));
        final end = DateTime.parse(
          change['ends_at'] as String,
        ).add(Duration(minutes: old?['return_minutes'] as int? ?? 0));
        if (_assignments(current).any(
          (row) =>
              row['id'] != old?['id'] &&
              row['active'] != false &&
              (row['command'] as PeopleCommand?)?.error == null &&
              DateTime.parse(
                (row['busy_start'] ?? row['starts_at']) as String,
              ).isBefore(end) &&
              start.isBefore(
                DateTime.parse((row['busy_end'] ?? row['ends_at']) as String),
              ),
        )) {
          _showError('Эта смена пересекается с другой сменой работника.');
          return;
        }
      }
      if (trip == null) {
        await _c.savePerson(
          {
            ...current.payload,
            'work_schedule': [
              for (final row in current.workSchedule)
                if (row['id'] != old?['id']) row,
              ?change,
            ],
          },
          teamId: current.teamId,
          previous: current,
        );
      } else {
        await _c.queueDuty(trip.id, {
          ...?old,
          ...?change,
          'resource_id': old?['resource_id'] ?? current.workResourceId,
          'capacity': 1,
          'active': change != null,
        }, expectedVersion: old?['version'] as int? ?? 0);
      }
    } catch (_) {
      _showError(
        'Не удалось сохранить смену. Проверьте предыдущие изменения графика.',
      );
    }
  }

  Future<void> _edit(
    PersonCard person,
    DateTime day, {
    JsonMap? old,
    Trip? trip,
    List<String>? roles,
  }) async {
    final result = await showDialog<JsonMap>(
      context: context,
      builder: (_) => WorkerShiftEditor(
        person: person,
        initialDay: day,
        shift: old,
        roles: roles,
        defaultStart: trip?.startsAt,
        defaultEnd: trip?.endsAt,
      ),
    );
    if (result != null && mounted) await _save(person, old, result, trip);
  }

  Future<void> _remove(PersonCard person, JsonMap old, Trip? trip) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Снять назначение?'),
        content: Text(_assignmentLabel(old)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Снять'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _save(person, old, null, trip);
  }

  Future<void> _openCell(
    PersonCard person,
    DateTime day,
    List<JsonMap> rows,
    TripTeam team,
  ) async {
    final trips =
        _c.trips
            .where(
              (t) =>
                  t.teamId == team.id &&
                  _editableTrip(t) &&
                  _overlaps(t.startsAt, t.endsAt, day),
            )
            .toList()
          ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    final escort = _roles(person, false);
    final kitchen = _roles(person, true);
    final canAssign = person.workResourceId != null && !person.pending;
    final canUseCampKitchen =
        team.canCreate &&
        !person.pending &&
        person.workRoles.contains('camp_kitchen');
    final action = await showDialog<Future<void> Function()>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: Text('${person.name} · ${_dateLabel(day)}'),
        children: [
          for (final row in rows)
            _assignmentOption(dialog, person, day, row, team),
          if (canUseCampKitchen)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(
                dialog,
                () => _edit(person, day, roles: ['camp_kitchen']),
              ),
              child: const Text('Добавить · Кухня лагеря'),
            ),
          if (canAssign)
            for (final trip in trips) ...[
              if (escort.isNotEmpty)
                _tripOption(
                  dialog,
                  person,
                  day,
                  trip,
                  'Команда сопровождения',
                  escort,
                ),
              if (kitchen.isNotEmpty)
                _tripOption(dialog, person, day, trip, 'Кухня выезда', kitchen),
            ],
          if (rows.isEmpty &&
              !canUseCampKitchen &&
              (!canAssign ||
                  trips.isEmpty ||
                  (escort.isEmpty && kitchen.isEmpty)))
            const SimpleDialogOption(
              child: Text('Нет доступных назначений на этот день.'),
            ),
        ],
      ),
    );
    if (action != null && mounted) await action();
  }

  Widget _tripOption(
    BuildContext dialog,
    PersonCard person,
    DateTime day,
    Trip trip,
    String category,
    List<String> roles,
  ) => SimpleDialogOption(
    onPressed: () => Navigator.pop(
      dialog,
      () => _edit(person, day, trip: trip, roles: roles),
    ),
    child: Text(
      '$category · ${trip.title}\n${tripDate(trip.startsAt, _zoneName)}',
    ),
  );

  Widget _assignmentOption(
    BuildContext dialog,
    PersonCard person,
    DateTime day,
    JsonMap row,
    TripTeam team,
  ) {
    final command = row['command'] as PeopleCommand?;
    final trip = _c.trips.where((t) => t.id == row['trip_id']).firstOrNull;
    final canEdit =
        command == null &&
        !person.pending &&
        (row['readonly'] == true
            ? trip != null && _editableTrip(trip)
            : team.canCreate);
    return ListTile(
      title: Text(_assignmentLabel(row)),
      subtitle: Text(
        command?.error != null
            ? operationsError(command!.error)
            : '${tripDate(DateTime.parse(row['starts_at'] as String), _zoneName)} — '
                  '${tripDate(DateTime.parse(row['ends_at'] as String), _zoneName)}'
                  '${command != null || (row['readonly'] != true && person.pending) ? ' · ожидает обмена' : ''}',
      ),
      onTap: canEdit
          ? () => Navigator.pop(
              dialog,
              () => _edit(person, day, old: row, trip: trip),
            )
          : null,
      trailing: command?.error != null
          ? IconButton(
              tooltip: 'Отменить локальную правку',
              icon: const Icon(Icons.undo),
              onPressed: () => Navigator.pop(
                dialog,
                () => _c.discardPeopleChange(command!.id),
              ),
            )
          : canEdit
          ? IconButton(
              tooltip: 'Снять назначение',
              icon: const Icon(Icons.delete_outline),
              onPressed: () =>
                  Navigator.pop(dialog, () => _remove(person, row, trip)),
            )
          : null,
    );
  }

  Widget _cell(
    BuildContext context,
    double width,
    double height,
    Widget child,
  ) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: child,
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _c,
    builder: (context, _) {
      final team =
          _c.teams.where((t) => t.id == _teamId).firstOrNull ??
          _c.teams.firstOrNull;
      final workers =
          _c.peopleView.people
              .where(
                (p) =>
                    p.teamId == team?.id &&
                    p.isWorker &&
                    !p.archived &&
                    p.mergedInto == null,
              )
              .toList()
            ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            );
      final start = _month
          ? tz.TZDateTime(_zone, _anchor.year, _anchor.month)
          : _monday(_anchor);
      final length = _month
          ? DateTime(_anchor.year, _anchor.month + 1, 0).day
          : 7;
      final days = [for (var i = 0; i < length; i++) _day(start, i)];
      final assignments = {for (final p in workers) p.id: _assignments(p)};
      final rowHeight = (MediaQuery.textScalerOf(context).scale(13) * 5 + 24)
          .clamp(96.0, 220.0);
      final nameWidth = MediaQuery.sizeOf(context).width < 520 ? 118.0 : 184.0;
      return SyncRefreshScope(
        controller: _c,
        child: Scaffold(
          appBar: AppBar(
            toolbarHeight: syncToolbarHeight(context),
            title: SyncPageTitle(title: 'График работ', controller: _c),
            actions: [RefreshAction(controller: _c)],
          ),
          body: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    if (_c.teams.length > 1)
                      SizedBox(
                        width: 300,
                        child: DropdownButtonFormField<String>(
                          key: ValueKey(team?.id),
                          initialValue: team?.id,
                          isExpanded: true,
                          focusColor: Colors.white,
                          dropdownColor: Colors.white,
                          decoration: const InputDecoration(isDense: true),
                          onChanged: (id) => setState(() => _teamId = id),
                          items: [
                            for (final item in _c.teams)
                              DropdownMenuItem(
                                value: item.id,
                                child: Text(item.name, overflow: TextOverflow.ellipsis),
                              ),
                          ],
                        ),
                      ),
                    IconButton(
                      tooltip: 'Предыдущий период',
                      icon: const Icon(Icons.chevron_left),
                      onPressed: () => _movePeriod(-1),
                    ),
                    TextButton(
                      onPressed: () =>
                          setState(() => _anchor = tz.TZDateTime.now(_zone)),
                      child: const Text('Сегодня'),
                    ),
                    IconButton(
                      tooltip: 'Следующий период',
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () => _movePeriod(1),
                    ),
                    ChoiceChip(
                      label: const Text('Неделя'),
                      selected: !_month,
                      onSelected: (_) => setState(() => _month = false),
                    ),
                    ChoiceChip(
                      label: const Text('Месяц'),
                      selected: _month,
                      onSelected: (_) => setState(() => _month = true),
                    ),
                    Text(
                      '${tripDate(days.first, _zoneName, includeTime: false)} — '
                      '${tripDate(days.last, _zoneName, includeTime: false)}',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (team == null || workers.isEmpty)
                  const Text('В выбранной команде пока нет работников.')
                else ...[
                  Row(
                    children: [
                      _cell(
                        context,
                        nameWidth,
                        48,
                        const Center(child: Text('Персонал')),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _header,
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final day in days)
                                _cell(
                                  context,
                                  _dayWidth,
                                  48,
                                  Center(child: Text(_dateLabel(day))),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          PeopleConflicts(controller: _c),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Column(
                                children: [
                                  for (final worker in workers)
                                    _cell(
                                      context,
                                      nameWidth,
                                      rowHeight,
                                      Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text(
                                            worker.name,
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              Expanded(
                                child: SingleChildScrollView(
                                  controller: _body,
                                  scrollDirection: Axis.horizontal,
                                  child: Column(
                                    children: [
                                      for (final worker in workers)
                                        Row(
                                          children: [
                                            for (final day in days)
                                              _dayCell(
                                                context,
                                                worker,
                                                day,
                                                assignments[worker.id]!,
                                                team,
                                                rowHeight,
                                              ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _dayCell(
    BuildContext context,
    PersonCard worker,
    DateTime day,
    List<JsonMap> assignments,
    TripTeam team,
    double height,
  ) {
    final rows = assignments
        .where(
          (row) => _overlaps(
            DateTime.parse(row['starts_at'] as String),
            DateTime.parse(row['ends_at'] as String),
            day,
          ),
        )
        .toList();
    final theme = Theme.of(context);
    return _cell(
      context,
      _dayWidth,
      height,
      InkWell(
        onTap: () => _openCell(worker, day, rows, team),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: rows.isEmpty
              ? const Center(
                  child: Icon(
                    Icons.add,
                    size: 18,
                    semanticLabel: 'Добавить назначение',
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 3,
                  children: [
                    for (final row in rows.take(2))
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color:
                              (row['command'] as PeopleCommand?)?.error != null
                              ? theme.colorScheme.errorContainer
                              : theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Row(
                            spacing: 4,
                            children: [
                              Expanded(
                                child: Text(
                                  '${_assignmentLabel(row, showPayment: false)}'
                                  '${row['command'] != null || (row['readonly'] != true && worker.pending) ? ' ⏳' : ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                              if (row['paid'] == true)
                                const Tooltip(
                                  message: 'Оплачено',
                                  child: Text(
                                    '0',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    if (rows.length > 2)
                      Text(
                        'Ещё ${rows.length - 2}',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}
