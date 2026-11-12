import '../people/worker_schedule.dart';
import '../people/work_schedule_screen.dart';
import '../../app/instructor_brand.dart';
import 'package:flutter/material.dart';
import '../../core/prototype.dart';
import '../operations/operations_widgets.dart';
import '../operations/reservation_editor.dart';
import '../resources/resources_screen.dart';
import '../trips/trip_presentation.dart';

class StaffScreen extends StatelessWidget {
  const StaffScreen({super.key, required this.controller});
  final Stage1Controller controller;

  Future<void> _moveEscort(
    BuildContext context,
    Trip source,
    List<JsonMap> escort,
  ) async {
    final target = await chooseDestinationTrip(
      context,
      controller.trips.where(
        (t) =>
            t.teamId == source.teamId &&
            t.id != source.id &&
            t.version > 0 &&
            ['open', 'closed', 'in_progress'].contains(t.status),
      ),
      title: 'Перенести команду сопровождения',
      detail:
          'Все назначения команды перейдут на выбранный выезд. Время каждой смены сдвинется вместе с началом выезда.',
    );
    if (target == null ||
        !context.mounted ||
        controller.selectedTripId != source.id) {
      return;
    }
    await performOperation(context, controller, 'ops_move_escort', {
      'target_trip_id': target.id,
      'versions': {
        for (final duty in escort) duty['id'] as String: duty['version'],
      },
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller, o = c.operationsView;
      final editable =
          c.selectedTrip != null &&
          !['completed', 'cancelled'].contains(c.selectedTrip!.status);
      final duties = o.bookings('duty'),
          employees = o.resources
              .where((r) => r['kind'] == 'employee')
              .toList();
      final escort = duties
          .where((d) => escortRoles.contains(d['role']))
          .toList();
      final canMoveEscort =
          editable &&
          escort.isNotEmpty &&
          !o.commands.any(
            (cmd) =>
                cmd.kind == 'ops_move_escort' && cmd.tripId == c.selectedTripId,
          );
      final instructors = o.instructorsOnWater(c.peopleView),
          needed = o.requiredInstructors(c.peopleView);
      return OperationsScroll(
        controller: c,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: editable
                    ? () => editReservation(context, c, 'duty')
                    : null,
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Назначить работу'),
              ),
              OutlinedButton(
                onPressed: canMoveEscort
                    ? () => _moveEscort(context, c.selectedTrip!, escort)
                    : null,
                child: const Text('Перенести команду сопровождения'),
              ),
              OutlinedButton(
                onPressed: () => openResources(context, c, 'employee'),
                child: const Text('Работники'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => WorkScheduleScreen(
                      controller: c,
                      initialTrip: c.selectedTrip,
                    ),
                  ),
                ),
                child: const Text('График работ'),
              ),
              TextButton(
                onPressed: () => operationsHistory(context, c),
                child: const Text('История'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Notice(
            text:
                'Инструкторов в экипажах: $instructors · требуется $needed. '
                'Работник лагеря в резерве не считается вторым инструктором на воде, пока не включён в состав и экипаж.',
            color: instructors < needed
                ? const Color(0xffa53c30)
                : const Color(0xff087c53),
          ),
          const Text(
            'Роли лагеря и подмена',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          for (final role in ['warehouse', 'camp_kitchen', 'relief'])
            Text(
              '${workerRoles[role]}: '
              '${employees.where((r) => (r['roles'] as List? ?? []).contains(role) && r['available'] == true).map((r) => r['name']).join(', ').isEmpty ? 'не указан' : employees.where((r) => (r['roles'] as List? ?? []).contains(role) && r['available'] == true).map((r) => r['name']).join(', ')}',
            ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Роли и подмена хранятся в справочнике работников. Конкретные смены и работа на выездах назначаются ниже.',
            ),
          ),
          Text(
            'Работа на этом выезде · ${duties.length}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (duties.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Назначений пока нет. Выберите работника, его специализацию и время.',
              ),
            ),
          for (final b in duties)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [
                    Row(
                      children: [
                        b['role'] == 'water_instructor'
                            ? const InstructorMark()
                            : const Icon(Icons.badge_outlined),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${reservationName(o, b)} · ${workerRoles[b['role']] ?? b['role']}${b['paid'] == true ? ' · 0 · Оплачено' : ''}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (editable)
                          PopupMenuButton<String>(
                            tooltip: 'Работа сотрудника',
                            onSelected: (v) {
                              if (v == 'edit') {
                                editReservation(context, c, 'duty', b);
                              }
                              if (v == 'cancel') {
                                cancelReservation(context, c, b);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'edit',
                                child: Text('Изменить назначение'),
                              ),
                              PopupMenuItem(
                                value: 'cancel',
                                child: Text('Отменить назначение'),
                              ),
                            ],
                          ),
                      ],
                    ),
                    Text(reservationDates(c, b)),
                    if (c.peopleView.person(
                          o.resource(b['resource_id'] as String)?['person_id']
                                  as String? ??
                              '',
                        )
                        case final PersonCard worker)
                      TextButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => WorkerSchedule(
                              controller: c,
                              personId: worker.id,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.calendar_month),
                        label: const Text('График работника'),
                      ),

                    if (b['pending'] == true)
                      const Text(
                        'Предварительное назначение',
                        style: TextStyle(color: Color(0xff946300)),
                      ),
                    if ((b['notes'] as String? ?? '').isNotEmpty)
                      Text(b['notes'] as String),
                    if (b['role'] == 'water_instructor')
                      _instructorStatus(context, c, b),
                    if (b['role'] == 'camp_worker')
                      const Text(
                        'Резерв: при выходе на воду добавьте работника в состав как инструктора и назначьте место. При одновременной работе в лагере он не заменяет второго инструктора.',
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Text(
            'Кадровый резерв',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          for (final target in workerTargets.entries)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${workerRoles[target.key]}: ${employees.where((r) => r['available'] == true && (r['roles'] as List? ?? []).contains(target.key)).length}'
                ' · ориентир ${target.value.$1 == target.value.$2 ? '${target.value.$1}' : '${target.value.$1}–${target.value.$2}'}',
              ),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Один работник не может одновременно выполнять два пересекающихся назначения. '
              'При смене роли измените назначение и при необходимости проезд и экипаж. Неизвестные имена работников не подставляются автоматически.',
            ),
          ),
        ],
      );
    },
  );
  Widget _instructorStatus(
    BuildContext context,
    Stage1Controller c,
    JsonMap b,
  ) {
    final person = c.operationsView.resource(
      b['resource_id'] as String,
    )?['person_id'];
    final p = c.peopleView.participations
        .where(
          (p) =>
              p.personId == person &&
              p.role == 'instructor' &&
              (p.requestedStatus ?? p.status) == 'confirmed',
        )
        .firstOrNull;
    final assigned =
        p != null && c.operationsView.crew(p.id)?['reservation_id'] != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          assigned
              ? 'Инструктор назначен в байдарку'
              : 'Добавьте инструктора на странице байдарок. Он учитывается отдельно от участников и трансфера.',
          style: TextStyle(
            color: assigned ? const Color(0xff087c53) : const Color(0xff946300),
          ),
        ),
        if (!assigned)
          TextButton(
            onPressed: () => DefaultTabController.of(context).animateTo(3),
            child: const Text('К байдаркам'),
          ),
      ],
    );
  }
}
