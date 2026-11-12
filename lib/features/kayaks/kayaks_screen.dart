import '../../app/instructor_brand.dart';
import 'package:uuid/uuid.dart';
import '../people/person_editor.dart';
import '../../core/company_color.dart';
import 'package:flutter/material.dart';
import '../../core/prototype.dart';
import '../operations/operations_widgets.dart';
import '../operations/reservation_editor.dart';
import '../resources/resources_screen.dart';

class KayaksScreen extends StatelessWidget {
  const KayaksScreen({super.key, required this.controller});
  final Stage1Controller controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller, o = c.operationsView, view = c.peopleView;
      final editable =
          c.selectedTrip != null &&
          !['completed', 'cancelled'].contains(c.selectedTrip!.status);
      final historical = operationRows(o.server['imported_crews']);
      final importedIds = {
        for (final crew in historical)
          ...(crew['participation_ids'] as List).cast<String>(),
      };
      final boats = o.bookings('boat'),
          unassigned = o
              .unassigned(view)
              .where((p) => !importedIds.contains(p.id))
              .toList();
      final needed = o.requiredInstructors(view),
          actual = o.instructorsOnWater(view);
      return OperationsScroll(
        controller: c,
        children: [
          if (boats.any((b) => b['planned'] == true))
            const Notice(
              text:
                  'Байдарки с пометкой «План» созданы автоматически для компаний. Выберите конкретные лодки из парка через редактирование байдарки.',
            ),
          if (historical.isNotEmpty) ...[
            const Notice(
              text:
                  'Историческая рассадка из Excel. Номера относятся к экипажам этого выезда; физические лодки и их типы в источнике не указаны. Парк и его брони не изменены.',
            ),
            for (final crew in historical)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 6,
                    children: [
                      Text(
                        crew['label'] as String,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      for (final id in crew['participation_ids'] as List)
                        Text(subjectName(c, 'participant', id as String)),
                      if ((crew['participation_ids'] as List).isEmpty)
                        Text(crew['note'] as String),
                    ],
                  ),
                ),
              ),
          ],
          if (historical.isEmpty || editable) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: editable
                      ? () => editReservation(context, c, 'boat')
                      : null,
                  icon: const Icon(Icons.add),
                  label: const Text('Забронировать лодку'),
                ),
                FilledButton.tonalIcon(
                  onPressed: editable
                      ? () => quickInstructor(context, c)
                      : null,
                  icon: const Icon(Icons.sports),
                  label: const Text('Добавить инструктора'),
                ),
                OutlinedButton(
                  onPressed: () => openResources(context, c, 'boat'),
                  child: const Text('Парк'),
                ),
                TextButton(
                  onPressed: () => operationsHistory(context, c),
                  child: const Text('История'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Лодок: ${boats.length} · без места: ${unassigned.length}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Notice(
              text:
                  'Инструкторов на воде: $actual · требуется $needed. '
                  'Считаются подтверждённые инструкторы, назначенные в экипажи.',
              color: actual < needed
                  ? const Color(0xffa53c30)
                  : const Color(0xff087c53),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('В группе много детей — нужны 2 инструктора'),
              subtitle: const Text(
                'При 35 и более подтверждённых клиентах два инструктора требуются автоматически.',
              ),
              value: o.settings['many_children'] == true,
              onChanged: editable
                  ? (v) => performOperation(
                      context,
                      c,
                      'ops_settings',
                      {'many_children': v, 'notes': o.settings['notes'] ?? ''},
                      version: o.settings['version'] as int? ?? 0,
                    )
                  : null,
            ),
            if (boats.isEmpty && historical.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Лодки пока не забронированы. Сначала проверьте парк, затем добавьте бронь.',
                ),
              ),
            for (final b in boats)
              _BoatCard(controller: c, booking: b, editable: editable),
            Card(
              child: ExpansionTile(
                initiallyExpanded: true,
                title: Text('Без места на воде · ${unassigned.length}'),
                subtitle: const Text(
                  'Клиенты и инструкторы из подтверждённого состава',
                ),
                children: [
                  if (unassigned.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Все подтверждённые участники распределены.'),
                    ),
                  for (final p in unassigned)
                    Draggable<Participation>(
                      data: p,
                      feedback: Material(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            view.person(p.personId)?.name ?? 'Участник',
                          ),
                        ),
                      ),
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          p.role == 'instructor'
                              ? Icons.sports
                              : Icons.person_outline,
                          color: p.role == 'instructor'
                              ? const Color(0xff7252a8)
                              : null,
                        ),
                        title: Text(
                          view.person(p.personId)?.name ?? 'Участник',
                        ),
                        subtitle: Text(
                          p.role == 'instructor' ? 'Инструктор' : 'Клиент',
                        ),
                        trailing: IconButton(
                          tooltip: 'Назначить в байдарку',
                          onPressed: editable && boats.isNotEmpty
                              ? () => assignCrew(context, c, participant: p)
                              : null,
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Новое участие и лист ожидания не занимают плановое место до подтверждения. Отмена освобождает рассадку; факты выхода на воду остаются в истории.',
              ),
            ),
          ],
        ],
      );
    },
  );
}

class _BoatCard extends StatelessWidget {
  const _BoatCard({
    required this.controller,
    required this.booking,
    required this.editable,
  });
  final Stage1Controller controller;
  final JsonMap booking;
  final bool editable;
  @override
  Widget build(BuildContext context) {
    final c = controller,
        o = c.operationsView,
        b = booking,
        resource = o.resource(b['resource_id'] as String)!;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 125,
              child: Column(
                children: [
                  const Icon(Icons.kayaking_outlined, size: 34),
                  Text('${resource['name']}', textAlign: TextAlign.center),
                  Text('${b['capacity']} мест'),
                  if (editable)
                    IconButton(
                      tooltip: 'Изменить лодку',
                      onPressed: () => editReservation(context, c, 'boat', b),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  for (var seat = 1; seat <= (b['capacity'] as int); seat++)
                    _seat(context, c, b, resource, seat),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _seat(
    BuildContext context,
    Stage1Controller c,
    JsonMap b,
    JsonMap resource,
    int seat,
  ) {
    final o = c.operationsView;
    final allocation = o.crews
        .where((r) => r['reservation_id'] == b['id'] && r['seat'] == seat)
        .firstOrNull;
    final p = c.peopleView.participations
        .where((r) => r.id == allocation?['registration_id'])
        .firstOrNull;
    bool canPlace(Participation value) {
      if (!boatSeatEligible(
        resource,
        b['capacity'] as int,
        seat,
        value.parameters,
      )) {
        return false;
      }
      if (p == null) return true;
      final old = o.crew(value.id),
          source = o.reservation(
            o.crew(value.id)?['reservation_id'] as String?,
          );
      final sourceResource = o.resource(source?['resource_id'] as String?);
      return p.id != value.id &&
          old?['seat'] is int &&
          source != null &&
          sourceResource != null &&
          boatSeatEligible(
            sourceResource,
            source['capacity'] as int,
            old!['seat'] as int,
            p.parameters,
          );
    }

    Future<void> place(Participation value) async {
      if (!canPlace(value)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Параметры участника не подходят для этого места.'),
          ),
        );
        return;
      }
      await performOperation(context, c, 'ops_crew', {
        'subject_kind': 'participant',
        'subject_id': value.id,
        'reservation_id': b['id'],
        'seat': seat,
        if (p != null) 'swap_id': p.id,
        if (p != null) 'swap_version': allocation!['version'],
      }, version: o.crew(value.id)?['version'] as int? ?? 0);
    }

    final content = Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: p?.role == 'instructor'
            ? instructorColor
            : p == null
            ? Colors.white
            : companyColor(p.bookingId),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          if (p?.role == 'instructor')
            const InstructorMark()
          else
            Text('$seat', style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              p == null
                  ? 'Свободное место'
                  : subjectName(c, 'participant', p.id),
            ),
          ),
          if (editable)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Назначить / перенести',
              onPressed: () => assignCrew(
                context,
                c,
                participant: p,
                booking: b,
                seat: seat,
              ),
              icon: const Icon(Icons.person_add_alt, size: 18),
            ),
        ],
      ),
    );
    final target = DragTarget<Participation>(
      onWillAcceptWithDetails: (d) => editable && canPlace(d.data),
      onAcceptWithDetails: (d) => place(d.data),
      builder: (context, candidates, rejected) => Container(
        decoration: BoxDecoration(
          border: candidates.isEmpty
              ? null
              : Border.all(color: Colors.teal, width: 2),
        ),
        child: content,
      ),
    );
    if (p == null || !editable) return target;
    return Draggable<Participation>(
      data: p,
      feedback: Material(
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(subjectName(c, 'participant', p.id)),
        ),
      ),
      childWhenDragging: Opacity(opacity: .35, child: target),
      child: target,
    );
  }
}

Future<void> assignCrew(
  BuildContext context,
  Stage1Controller c, {
  Participation? participant,
  JsonMap? booking,
  int? seat,
}) async {
  final result = await operationDialog<JsonMap>(
    context,
    c,
    _CrewEditor(
      controller: c,
      participant: participant,
      booking: booking,
      seat: seat,
    ),
  );
  if (result != null && context.mounted) {
    await performOperation(
      context,
      c,
      'ops_crew',
      result,
      version: result['expected_version'] as int,
    );
  }
}

class _CrewEditor extends StatefulWidget {
  const _CrewEditor({
    required this.controller,
    this.participant,
    this.booking,
    this.seat,
  });
  final Stage1Controller controller;
  final Participation? participant;
  final JsonMap? booking;
  final int? seat;
  @override
  State<_CrewEditor> createState() => _CrewEditorState();
}

class _CrewEditorState extends State<_CrewEditor> {
  late String? _person = widget.participant?.id,
      _booking = widget.booking?['id'] as String?;
  late int? _seat = widget.seat;
  String? _error;
  late final _versions = {
    for (final r in widget.controller.operationsView.crews)
      r['registration_id'] as String: r['version'] as int,
  };
  @override
  Widget build(BuildContext context) {
    final c = widget.controller, o = c.operationsView;
    final people = c.peopleView.participations
        .where(
          (p) =>
              (p.requestedStatus ?? p.status) == 'confirmed' &&
              p.data['legacy'] != true,
        )
        .toList();
    if (_person != null && !people.any((p) => p.id == _person)) _person = null;
    if (_booking != null &&
        !o.bookings('boat').any((b) => b['id'] == _booking)) {
      _booking = null;
      _seat = null;
    }
    final p = people.where((p) => p.id == _person).firstOrNull,
        b = o.reservation(_booking);
    final resource = o.resource(b?['resource_id'] as String?);
    JsonMap? occupant(int? seat) => o.crews
        .where(
          (r) =>
              r['reservation_id'] == _booking &&
              r['seat'] == seat &&
              r['registration_id'] != _person,
        )
        .firstOrNull;
    final target = occupant(_seat);

    return AlertDialog(
      title: const Text('Место в байдарке'),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _person,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Участник'),
              items: [
                for (final p in people)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text(
                      '${c.peopleView.person(p.personId)?.name ?? 'Участник'}${p.role == 'instructor' ? ' · инструктор' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() {
                _person = v;
                _error = null;
              }),
            ),
            DropdownButtonFormField<String>(
              initialValue: _booking,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Байдарка'),
              items: [
                for (final b in o.bookings('boat'))
                  DropdownMenuItem(
                    value: b['id'] as String,
                    child: Text(
                      '${reservationName(o, b)} · ${b['capacity']} мест',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() {
                _booking = v;
                _seat = null;
                _error = null;
              }),
            ),
            if (b != null && resource != null)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var seat = 1; seat <= (b['capacity'] as int); seat++)
                    ChoiceChip(
                      label: Text(
                        '$seat · ${occupant(seat) == null ? seatDescription(resource, b['capacity'] as int, seat) : subjectName(c, 'participant', occupant(seat)!['registration_id'] as String)}',
                      ),
                      selected: _seat == seat,
                      onSelected: (_) => setState(() {
                        _seat = seat;
                        _error = null;
                      }),
                    ),
                ],
              ),
            if (p != null)
              Text(
                'Рост: ${p.parameters['height_cm'] ?? 'не указан'} · вес: ${p.parameters['weight_kg'] ?? 'не указан'} · возраст: ${p.parameters['age_years'] ?? 'не указан'}',
              ),
            const Text(
              'При переносе прежнее плановое место освобождается одной операцией. Факт присутствия не перемещается автоматически.',
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
            String? error;
            if (p == null || b == null || _seat == null) {
              error = 'Выберите участника, лодку и место.';
            } else if (!boatSeatEligible(
              resource!,
              b['capacity'] as int,
              _seat!,
              p.parameters,
            )) {
              error = operationsError('seat_restriction');
            } else if (target != null) {
              final old = o.crew(p.id),
                  source = o.reservation(
                    o.crew(p.id)?['reservation_id'] as String?,
                  );
              final peer = people
                  .where((v) => v.id == target['registration_id'])
                  .firstOrNull;
              final r = o.resource(source?['resource_id'] as String?);
              if (old?['seat'] is! int ||
                  source == null ||
                  peer == null ||
                  r == null) {
                error = 'Для обмена у обоих участников должны быть места.';
              } else if (!boatSeatEligible(
                r,
                source['capacity'] as int,
                old!['seat'] as int,
                peer.parameters,
              )) {
                error = operationsError('seat_restriction');
              }
            }

            if (error != null) {
              setState(() => _error = error);
              return;
            }
            Navigator.pop(context, <String, dynamic>{
              'subject_kind': 'participant',
              'subject_id': p!.id,
              'reservation_id': b!['id'],
              'seat': _seat,
              'expected_version': _versions[p.id] ?? 0,
              if (target != null) 'swap_id': target['registration_id'],
              if (target != null)
                'swap_version': _versions[target['registration_id']] ?? 0,
            });
          },
          child: const Text('Назначить место'),
        ),
      ],
    );
  }
}

Future<void> quickInstructor(BuildContext context, Stage1Controller c) async {
  final chosen = await showDialog<Object>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Добавить инструктора'),
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final p in c.peopleView.participations.where(
              (p) => p.role == 'instructor' && p.status != 'cancelled',
            ))
              ListTile(
                dense: true,
                leading: const InstructorMark(),
                title: Text(subjectName(c, 'participant', p.id)),
                subtitle: const Text('В составе сплава'),
                onTap: () => Navigator.pop(dialog, p),
              ),
            for (final person in c.peopleView.people.where(
              (p) =>
                  p.teamId == c.selectedTrip!.teamId &&
                  !p.archived &&
                  p.mergedInto == null &&
                  !c.peopleView.participations.any((m) => m.personId == p.id),
            ))
              ListTile(
                dense: true,
                title: Text(person.name),
                onTap: () => Navigator.pop(dialog, person),
              ),
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(dialog, 'new'),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Новый инструктор'),
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
  if (chosen == null || !context.mounted) return;
  Participation? p;
  if (chosen is Participation) {
    p = chosen;
  } else {
    JsonMap? raw;
    if (chosen == 'new') {
      raw = await showDialog<JsonMap>(
        context: context,
        builder: (_) => PersonEditor(
          teams: c.teams,
          people: c.peopleView.people,
          teamId: c.selectedTrip!.teamId,
        ),
      );
      if (raw == null || !context.mounted) return;
    }
    final existing = chosen is PersonCard
        ? chosen
        : raw?['use_existing'] is String
        ? c.peopleView.person(raw!['use_existing'] as String)
        : null;
    if (existing != null &&
        c.peopleView.participations.any((p) => p.personId == existing.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Этот человек уже есть в составе. Измените его роль в параметрах участника.',
          ),
        ),
      );
      return;
    }
    final person = existing?.data ?? {...raw!, 'id': const Uuid().v4()};
    final id = const Uuid().v4();
    try {
      await c.saveBooking({
        'contact_person_id': person['id'],
        'contact_name': person['name'],
        'phone': person['phone'] ?? '',
        'notes': 'Инструктор',
        'members': [
          {
            'id': id,
            'person_id': person['id'],
            'role': 'instructor',
            'parameters': person['parameters'] ?? {},
          },
        ],
      }, newPeople: existing == null ? [person] : []);
      p = c.peopleView.participations.where((p) => p.id == id).firstOrNull;
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось добавить инструктора. Проверьте данные.'),
          ),
        );
      }
      return;
    }
  }
  if (!context.mounted || p == null) return;
  if (c.operationsView.crew(p.id)?['reservation_id'] != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Инструктор уже назначен в свою байдарку.')),
    );
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Инструктор добавлен. Его отдельная байдарка появится после обмена.',
        ),
      ),
    );
  }
}
