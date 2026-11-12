import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../core/prototype.dart';
import '../operations/operations_widgets.dart';
import '../operations/reservation_editor.dart';
import '../resources/resources_screen.dart';

class TransportScreen extends StatefulWidget {
  const TransportScreen({super.key, required this.controller});
  final Stage1Controller controller;
  @override
  State<TransportScreen> createState() => _TransportScreenState();
}

class _TransportScreenState extends State<TransportScreen> {
  String _direction = 'outbound';
  Future<void> _extraBus() async {
    final c = widget.controller, t = widget.controller.selectedTrip!;
    final start = _direction == 'outbound'
        ? t.startsAt.subtract(const Duration(hours: 1))
        : t.endsAt;
    final end = _direction == 'outbound'
        ? t.startsAt
        : t.endsAt.add(const Duration(hours: 1));
    final vehicles = c.operationsView.resources
        .where(
          (r) =>
              r['kind'] == 'vehicle' &&
              r['available'] == true &&
              !c.operationsView.resourceBusy(r['id'] as String, start, end),
        )
        .toList();
    final chosen = await showDialog<JsonMap>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Следующий автобус'),
        scrollable: true,
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Участники без проезда займут свободные места выбранного автобуса.',
              ),
              for (final v in vehicles)
                ListTile(
                  leading: const Icon(Icons.directions_bus),
                  title: Text('${v['name']}'),
                  subtitle: Text('${v['capacity']} мест'),
                  onTap: () => Navigator.pop(dialog, v),
                ),
              OutlinedButton.icon(
                onPressed: () =>
                    Navigator.pop(dialog, <String, dynamic>{'create': true}),
                icon: const Icon(Icons.add),
                label: const Text('Новый автобус'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Отмена'),
          ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    JsonMap vehicle = chosen;
    if (chosen['create'] == true) {
      final result = await showDialog<JsonMap>(
        context: context,
        builder: (_) => ResourceEditor(
          controller: c,
          kind: 'vehicle',
          initialModel: 'secondary_bus',
        ),
      );
      if (result == null || !mounted) return;
      try {
        await c.queueOperations('ops_resources', {
          'items': [result],
        });
      } catch (_) {
        return;
      }
      vehicle = result;
    }
    if (!mounted) return;
    await performOperation(context, c, 'ops_reservation', {
      'id': const Uuid().v4(),
      'kind': 'ride',
      'resource_id': vehicle['id'],
      'starts_at': start.toUtc().toIso8601String(),
      'ends_at': end.toUtc().toIso8601String(),
      'capacity': vehicle['capacity'],
      'direction': _direction,
      'active': true,
      'prep_minutes': 0,
      'return_minutes': 0,
      'points': [
        {'id': 'auto-meeting', 'name': 'Свободная посадка'},
      ],
      'notes': 'Дополнительный автобус · автоматическое заполнение',
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller, o = c.operationsView;
      final editable =
          _direction == 'outbound' &&
          c.selectedTrip != null &&
          !['completed', 'cancelled'].contains(c.selectedTrip!.status);
      final rides = o
          .bookings('ride')
          .where((b) => b['direction'] == _direction)
          .toList();
      final people = c.peopleView.participations
          .where(
            (p) =>
                p.role == 'client' &&
                (p.requestedStatus ?? p.status) == 'confirmed' &&
                p.data['legacy'] != true,
          )
          .toList();
      final unplanned = people
          .where(
            (p) => ![
              'bus',
              'self',
            ].contains(o.journey('participant', p.id, _direction)?['mode']),
          )
          .length;
      final self = o.travel
          .where(
            (t) =>
                t['direction'] == _direction &&
                t['mode'] == 'self' &&
                (t['subject_kind'] != 'participant' ||
                    c.peopleView.participations.any(
                      (p) => p.id == t['subject_id'] && p.role == 'client',
                    )),
          )
          .toList();
      return OperationsScroll(
        controller: c,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: editable
                    ? () => editReservation(context, c, 'ride')
                    : null,
                icon: const Icon(Icons.add),
                label: const Text('Добавить рейс'),
              ),
              OutlinedButton(
                onPressed: () => openResources(context, c, 'vehicle'),
                child: const Text('Транспорт'),
              ),
              OutlinedButton(
                onPressed: editable
                    ? () => editTravel(context, c, direction: _direction)
                    : null,
                child: const Text('Назначить пассажира'),
              ),
              TextButton(
                onPressed: () => operationsHistory(context, c),
                child: const Text('История'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final dir in ['outbound', 'return'])
                ChoiceChip(
                  label: Text(directionLabel(dir)),
                  selected: _direction == dir,
                  onSelected: (_) => setState(() => _direction = dir),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Рейсов: ${rides.length} · самостоятельно: ${self.length} · проезд не указан: $unplanned',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (unplanned > 0 && _direction == 'outbound') ...[
            Notice(
              text:
                  'Без места: $unplanned. Наш автобус заполняется автоматически при сохранении участников. Если мест не хватило, выберите следующий автобус.',
            ),
            FilledButton.tonalIcon(
              onPressed: editable ? _extraBus : null,
              icon: const Icon(Icons.directions_bus),
              label: Text('Добавить автобус · $unplanned без места'),
            ),
          ],
          for (final b in rides)
            _RideCard(controller: c, booking: b, editable: editable),
          if (rides.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('В этом направлении пока нет рейсов.'),
            ),
          Card(
            child: ExpansionTile(
              title: Text(
                'Проезд участников · ${directionLabel(_direction).toLowerCase()}',
              ),
              children: [
                for (final p in people)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      p.role == 'instructor'
                          ? Icons.sports
                          : Icons.person_outline,
                    ),
                    title: Text(subjectName(c, 'participant', p.id)),
                    subtitle: Text(
                      _travelCaption(
                        o,
                        o.journey('participant', p.id, _direction),
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: 'Указать проезд',
                      onPressed: editable
                          ? () => editTravel(
                              context,
                              c,
                              direction: _direction,
                              kind: 'participant',
                              subject: p.id,
                            )
                          : null,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ),
                for (final t in o.travel.where(
                  (t) =>
                      t['subject_kind'] == 'employee' &&
                      t['direction'] == _direction &&
                      t['mode'] != 'unset',
                ))
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.badge_outlined),
                    title: Text(
                      subjectName(c, 'employee', t['subject_id'] as String),
                    ),
                    subtitle: Text('Работник · ${_travelCaption(o, t)}'),
                    trailing: IconButton(
                      tooltip: 'Указать проезд',
                      onPressed: editable
                          ? () => editTravel(
                              context,
                              c,
                              direction: _direction,
                              kind: 'employee',
                              subject: t['subject_id'] as String,
                            )
                          : null,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

String _travelCaption(OperationsView o, JsonMap? t) =>
    t == null || t['mode'] == 'unset'
    ? 'Проезд не указан'
    : t['mode'] == 'self'
    ? 'Самостоятельно'
    : '${o.reservation(t['reservation_id'] as String) == null ? 'Рейс' : reservationName(o, o.reservation(t['reservation_id'] as String)!)}${t['pending'] == true ? ' · предварительно' : ''}';

class _RideCard extends StatelessWidget {
  const _RideCard({
    required this.controller,
    required this.booking,
    required this.editable,
  });
  final Stage1Controller controller;
  final JsonMap booking;
  final bool editable;
  @override
  Widget build(BuildContext context) {
    final c = controller, o = c.operationsView, b = booking;
    final plan =
        o.travel
            .where((t) => t['reservation_id'] == b['id'] && t['mode'] == 'bus')
            .toList()
          ..sort((a, b) => (a['seat'] as int).compareTo(b['seat'] as int));
    final actual = o.latestPresence.values
        .where((f) => f['reservation_id'] == b['id'] && f['present'] == true)
        .toList();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ExpansionTile(
        dense: true,
        leading: const Icon(Icons.directions_bus_outlined),
        title: Text(
          '${reservationName(o, b)} · ${plan.length}/${b['capacity']}',
        ),
        subtitle: Text(reservationDates(c, b)),
        childrenPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 4,
        ),
        children: [
          if (editable)
            Wrap(
              spacing: 4,
              children: [
                TextButton(
                  onPressed: () => editReservation(context, c, 'ride', b),
                  child: const Text('Изменить рейс'),
                ),
                TextButton(
                  onPressed: () => cancelReservation(context, c, b),
                  child: const Text('Отменить рейс'),
                ),
              ],
            ),
          if (b['pending'] == true)
            const Text(
              'Предварительный рейс · ожидает сервера',
              style: TextStyle(color: Color(0xff946300)),
            ),
          for (final t in plan) _passenger(context, c, b, t),
          if (editable)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => editTravel(
                  context,
                  c,
                  direction: b['direction'] as String,
                  booking: b,
                ),
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Добавить пассажира в рейс'),
              ),
            ),
          for (final f in actual.where(
            (f) => !plan.any(
              (t) =>
                  t['subject_kind'] == f['subject_kind'] &&
                  t['subject_id'] == f['subject_id'],
            ),
          ))
            Notice(
              text:
                  'Фактически присутствует вне плана: ${subjectName(c, f['subject_kind'] as String, f['subject_id'] as String)}',
              color: const Color(0xffa53c30),
            ),
        ],
      ),
    );
  }

  Widget _passenger(
    BuildContext context,
    Stage1Controller c,
    JsonMap b,
    JsonMap t,
  ) {
    final o = c.operationsView,
        kind = t['subject_kind'] as String,
        id = t['subject_id'] as String;
    final f = o.fact(b['id'] as String, kind, id),
        present = f?['present'] == true;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(subjectName(c, kind, id)),
      subtitle: t['pending'] == true || f?['pending'] == true
          ? const Text('Ожидает обмена')
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (editable)
            IconButton(
              tooltip: 'Изменить проезд',
              onPressed: () => editTravel(
                context,
                c,
                direction: 'outbound',
                kind: kind,
                subject: id,
              ),
              icon: const Icon(Icons.edit_outlined),
            ),
          IconButton(
            tooltip: present ? 'Снять отметку посадки' : 'Отметить посадку',
            onPressed:
                !['completed', 'cancelled'].contains(c.selectedTrip?.status) ||
                    present
                ? () => markPresence(context, c, b, kind, id, !present)
                : null,
            icon: Icon(
              present ? Icons.check_circle : Icons.check_circle_outline,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> editTravel(
  BuildContext context,
  Stage1Controller c, {
  required String direction,
  String? kind,
  String? subject,
  JsonMap? booking,
}) async {
  final result = await operationDialog<JsonMap>(
    context,
    c,
    _TravelEditor(
      controller: c,
      direction: direction,
      kind: kind,
      subject: subject,
      booking: booking,
    ),
  );
  if (result != null && context.mounted) {
    await performOperation(
      context,
      c,
      'ops_travel',
      result,
      version: result['expected_version'] as int,
    );
  }
}

class _TravelEditor extends StatefulWidget {
  const _TravelEditor({
    required this.controller,
    required this.direction,
    this.kind,
    this.subject,
    this.booking,
  });
  final Stage1Controller controller;
  final String direction;
  final String? kind, subject;
  final JsonMap? booking;
  @override
  State<_TravelEditor> createState() => _TravelEditorState();
}

class _TravelEditorState extends State<_TravelEditor> {
  late final _initial = {
    for (final t in widget.controller.operationsView.travel)
      travelKey(
        t['subject_kind'] as String,
        t['subject_id'] as String,
        t['direction'] as String,
      ): t,
  };
  String? _subject, _ride, _error;
  String _mode = 'bus';
  @override
  void initState() {
    super.initState();
    if (widget.subject != null) {
      _subject = subjectKey(widget.kind ?? 'participant', widget.subject!);
    }
    final old = widget.subject == null
        ? null
        : widget.controller.operationsView.journey(
            widget.kind ?? 'participant',
            widget.subject!,
            widget.direction,
          );
    _mode = old?['mode'] as String? ?? 'bus';
    _ride =
        widget.booking?['id'] as String? ?? old?['reservation_id'] as String?;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, o = c.operationsView;
    final subjects = <String, String>{
      for (final p in c.peopleView.participations.where(
        (p) =>
            p.role == 'client' &&
            ((p.requestedStatus ?? p.status) == 'confirmed' ||
                p.id == widget.subject),
      ))
        subjectKey(
          'participant',
          p.id,
        ): '${subjectName(c, 'participant', p.id)}${p.role == 'instructor' ? ' · инструктор' : ''}',
      for (final r in o.resources.where(
        (r) =>
            r['kind'] == 'employee' &&
            (r['available'] == true || r['id'] == widget.subject),
      ))
        subjectKey('employee', r['id'] as String): '${r['name']} · работник',
    };
    if (_subject != null && !subjects.containsKey(_subject)) _subject = null;
    if (_ride != null &&
        !o
            .bookings('ride')
            .any(
              (b) => b['id'] == _ride && b['direction'] == widget.direction,
            )) {
      _ride = null;
    }
    final b = o.reservation(_ride), points = operationRows(b?['points']);
    return AlertDialog(
      title: Text('Проезд · ${directionLabel(widget.direction).toLowerCase()}'),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _subject,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Пассажир'),
              items: [
                for (final p in subjects.entries)
                  DropdownMenuItem(
                    value: p.key,
                    child: Text(
                      p.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() {
                _subject = v;
                _error = null;
              }),
            ),
            DropdownButtonFormField<String>(
              initialValue: _mode,
              decoration: const InputDecoration(labelText: 'Способ проезда'),
              items: const [
                DropdownMenuItem(value: 'bus', child: Text('В рейсе')),
                DropdownMenuItem(value: 'self', child: Text('Самостоятельно')),
                DropdownMenuItem(
                  value: 'unset',
                  child: Text('Проезд не указан'),
                ),
              ],
              onChanged: (v) => setState(() {
                _mode = v!;
                _error = null;
              }),
            ),
            if (_mode == 'bus') ...[
              DropdownButtonFormField<String>(
                initialValue: _ride,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Рейс'),
                items: [
                  for (final ride
                      in o
                          .bookings('ride')
                          .where((r) => r['direction'] == widget.direction))
                    DropdownMenuItem(
                      value: ride['id'] as String,
                      child: Text(
                        '${reservationName(o, ride)} · ${ride['capacity']} мест',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _ride = v;
                  _error = null;
                }),
              ),
            ],
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
            final seat = b == null
                ? null
                : [
                    for (var seat = 1; seat <= (b['capacity'] as int); seat++)
                      if (!_occupied(o, b, seat)) seat,
                  ].firstOrNull;
            if (_subject == null ||
                (_mode == 'bus' && (seat == null || points.isEmpty))) {
              setState(
                () =>
                    _error = 'Выберите пассажира и рейс со свободными местами.',
              );
              return;
            }
            final index = _subject!.indexOf(':'),
                kind = _subject!.substring(0, index),
                id = _subject!.substring(index + 1);
            final old = _initial[travelKey(kind, id, widget.direction)];
            Navigator.pop(context, <String, dynamic>{
              'id': old?['id'] ?? const Uuid().v4(),
              'subject_kind': kind,
              'subject_id': id,
              'direction': widget.direction,
              'mode': _mode,
              'reservation_id': _mode == 'bus' ? _ride : null,
              'seat': _mode == 'bus' ? seat : null,
              'free_seating': true,
              'point_id': _mode == 'bus' ? points.first['id'] : null,
              'expected_version': old?['version'] ?? 0,
            });
          },
          child: const Text('Сохранить проезд'),
        ),
      ],
    );
  }

  bool _occupied(OperationsView o, JsonMap b, int seat) =>
      o.travel.any(
        (t) =>
            t['reservation_id'] == b['id'] &&
            t['seat'] == seat &&
            subjectKey(
                  t['subject_kind'] as String,
                  t['subject_id'] as String,
                ) !=
                _subject,
      ) ||
      o.latestPresence.values.any(
        (f) =>
            f['reservation_id'] == b['id'] &&
            f['seat'] == seat &&
            f['present'] == true &&
            subjectKey(
                  f['subject_kind'] as String,
                  f['subject_id'] as String,
                ) !=
                _subject,
      );
}
