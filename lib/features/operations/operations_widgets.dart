import 'package:flutter/material.dart';
import '../../core/prototype.dart';
import '../../app/sync_widgets.dart';
import '../trips/trip_format.dart';

Future<void> performOperation(
  BuildContext context,
  Stage1Controller c,
  String kind,
  JsonMap payload, {
  int version = 0,
}) async {
  try {
    await c.queueOperations(kind, payload, expectedVersion: version);
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is StateError
                ? error.message
                : 'Не удалось сохранить. Проверьте данные и предыдущие изменения.',
          ),
        ),
      );
    }
  }
}

Future<T?> operationDialog<T>(
  BuildContext context,
  Stage1Controller c,
  Widget child,
) {
  final trip = c.selectedTripId;
  return showDialog<T>(
    context: context,
    builder: (dialogContext) => ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (c.selectedTripId == trip && c.trips.any((t) => t.id == trip)) {
          return child;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (dialogContext.mounted &&
              ModalRoute.of(dialogContext)?.isCurrent == true) {
            Navigator.pop(dialogContext);
          }
        });
        return const AlertDialog(title: Text('Выезд недоступен'));
      },
    ),
  );
}

Future<String?> operationReason(
  BuildContext context,
  Stage1Controller c,
  String title, {
  String initial = '',
}) => operationDialog<String>(
  context,
  c,
  _ReasonDialog(title: title, initial: initial),
);

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({required this.title, required this.initial});
  final String title, initial;
  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final form = GlobalKey<FormState>();
  late final reason = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: Form(
        key: form,
        child: TextFormField(
          controller: reason,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Причина'),
          maxLines: 3,
          maxLength: 2000,
          validator: (v) => (v ?? '').trim().isEmpty ? 'Укажите причину' : null,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, reason.text.trim());
          }
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
}

String subjectName(Stage1Controller c, String kind, String id) {
  if (kind == 'employee') {
    return c.operationsView.resource(id)?['name'] as String? ?? 'Работник';
  }
  final p = c.peopleView.participations.where((p) => p.id == id).firstOrNull;
  return p == null
      ? 'Участник'
      : c.peopleView.person(p.personId)?.name ?? 'Участник';
}

String reservationName(OperationsView ops, JsonMap booking) =>
    ops.resource(booking['resource_id'] as String)?['name'] as String? ??
    'Ресурс';
String reservationDates(Stage1Controller c, JsonMap value) =>
    '${tripDate(DateTime.parse(value['starts_at'] as String), c.selectedTrip!.timeZone)} — '
    '${tripDate(DateTime.parse(value['ends_at'] as String), c.selectedTrip!.timeZone)}';

Future<void> markPresence(
  BuildContext context,
  Stage1Controller c,
  JsonMap booking,
  String kind,
  String id,
  bool present,
) async {
  var reason = '';
  if (!present) {
    final result = await operationReason(
      context,
      c,
      'Изменить отметку присутствия',
      initial: booking['kind'] == 'ride'
          ? 'Вышел из транспорта'
          : 'Вернулся на берег',
    );
    if (result == null || !context.mounted) return;
    reason = result;
  }
  if (!context.mounted) return;
  await performOperation(context, c, 'ops_presence', {
    'reservation_id': booking['id'],
    'subject_kind': kind,
    'subject_id': id,
    'present': present,
    'reason': reason,
  });
}

class OperationsStatus extends StatelessWidget {
  const OperationsStatus({super.key, required this.controller});
  final Stage1Controller controller;
  @override
  Widget build(BuildContext context) {
    final c = controller, o = c.operationsView;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!o.ready)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              c.isOffline
                  ? 'Данные этого раздела ещё не сохранены. Они загрузятся автоматически при появлении связи.'
                  : 'Загружаем лодки, транспорт и работников…',
            ),
          ),
        if (o.provisional)
          const Notice(
            text:
                'Есть предварительные назначения на устройстве. Места и доступность подтвердит сервер.',
            color: Color(0xff946300),
          ),
        for (final command in o.commands.where(
          (c) => c.error != null && c.tripId == controller.selectedTripId,
        ))
          Card(
            color: const Color(0xffffeeee),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text(
                    command.label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(operationsError(command.error)),
                  Text(_changeDescription(c, command)),
                  if (command.kind == 'ops_cabins')
                    const Text(
                      'Отмените локальную правку и обновите размещение по актуальному составу.',
                    )
                  else
                    const Text(
                      'Локальный вариант остаётся предварительным. При повторе будут использованы актуальные версии. Зависимые черновики будут отменены.',
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (command.kind != 'ops_resolve' &&
                          command.kind != 'ops_move_escort' &&
                          command.kind != 'ops_setup' &&
                          command.kind != 'ops_cabins')
                        OutlinedButton(
                          onPressed: () async {
                            try {
                              await c.retryOperations(command);
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Откройте актуальную запись и повторите изменение.',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                          child: const Text('Повторить с актуальными данными'),
                        ),
                      TextButton(
                        onPressed: () => c.discardPeopleChange(command.id),
                        child: const Text('Отменить локальную правку'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        for (final issue in o.issues(c.peopleView))
          Card(
            color: const Color(0xffffeeee),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  const Text(
                    'Факт присутствия расходится с планом',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Color(0xffa53c30),
                    ),
                  ),
                  Text(
                    '${subjectName(c, issue['subject_kind'] as String, issue['subject_id'] as String)} ${o.reservation(issue['reservation_id'] as String)?['kind'] == 'ride' ? '' : '· место ${issue['seat']}'}',
                  ),
                  const Text(
                    'Отметка сохранена. Проверьте, находится ли человек в транспорте или на воде.',
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final decision in const {
                        'keep': 'Факт верен',
                        'error': 'Ошибка отметки',
                      }.entries)
                        OutlinedButton(
                          onPressed:
                              c.peopleView.commands.any(
                                (v) => v.tripId == c.selectedTripId,
                              )
                              ? null
                              : () async {
                                  final reason = await operationReason(
                                    context,
                                    c,
                                    decision.value,
                                  );
                                  if (reason != null && context.mounted) {
                                    await performOperation(
                                      context,
                                      c,
                                      'ops_resolve',
                                      {
                                        'fact_id': issue['fact_id'],
                                        'signature': issue['signature'],
                                        'decision': decision.key,
                                        'reason': reason,
                                      },
                                    );
                                  }
                                },
                          child: Text(decision.value),
                        ),
                    ],
                  ),
                  if (c.peopleView.commands.any(
                    (v) => v.tripId == c.selectedTripId,
                  ))
                    const Text(
                      'Разбор станет доступен после подтверждения ожидающих изменений.',
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

String _changeDescription(Stage1Controller c, PeopleCommand command) {
  final p = command.payload, o = c.operationsView;
  if (command.kind == 'ops_travel') {
    return 'Ваш вариант: ${subjectName(c, p['subject_kind'] as String, p['subject_id'] as String)}';
  }
  if (p['subject_id'] != null) {
    return 'Ваш вариант: ${subjectName(c, p['subject_kind'] as String? ?? 'participant', p['subject_id'] as String)}'
        ' · ${p['seat'] == null ? 'без места' : 'место ${p['seat']}'}';
  }
  if (command.kind == 'ops_reservation') {
    final server = operationRows(
      o.server['reservations'],
    ).where((r) => r['id'] == p['id']).firstOrNull;
    return 'Ваш вариант: ${reservationName(o, p)} · ${p['capacity']} мест\n'
        '${server == null ? 'На сервере эта бронь ещё не создана.' : 'На сервере: ${server['capacity']} мест · ${reservationDates(c, server)}'}';
  }
  if (command.kind == 'ops_resources') {
    return operationRows(p['items']).map((r) => r['name']).join(', ');
  }
  return 'Изменение сохранено на устройстве.';
}

class Notice extends StatelessWidget {
  const Notice({
    super.key,
    required this.text,
    this.color = const Color(0xff946300),
  });
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .09),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: .25)),
    ),
    child: Text(text, style: TextStyle(color: color)),
  );
}

Future<void> operationsHistory(
  BuildContext context,
  Stage1Controller c,
) => operationDialog<void>(
  context,
  c,
  AlertDialog(
    title: const Text('История работы на выезде'),
    scrollable: true,
    content: SizedBox(
      width: 600,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          if (c.operationsView.presence.isEmpty &&
              c.operationsView.history.isEmpty)
            const Text('История пока пуста.'),
          for (final f in c.operationsView.presence.reversed)
            Text(
              '${subjectName(c, f['subject_kind'] as String, f['subject_id'] as String)} · ${f['present'] == true ? 'Присутствие отмечено' : 'Отметка снята'}\n'
              '${tripDate(DateTime.parse(f['occurred_at'] as String), c.selectedTrip!.timeZone)}'
              '${f['pending'] == true ? ' · на устройстве' : ' · подтверждено'}${(f['reason'] as String? ?? '').isEmpty ? '' : '\n${f['reason']}'}',
            ),
          for (final r in c.operationsView.resolutions.reversed)
            Text(
              'Разбор: ${r['decision'] == 'keep' ? 'факт верен' : 'ошибка отметки'}\n${r['reason']}',
            ),
          for (final h in c.operationsView.history.reversed.take(100))
            Text(
              '${PeopleCommand(id: '', teamId: '', kind: h['kind'] as String, payload: const {}, expectedVersion: 0).label}'
              ' · ${tripDate(DateTime.parse(h['created_at'] as String), c.selectedTrip!.timeZone)}',
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Закрыть'),
      ),
    ],
  ),
);

class OperationsScroll extends StatelessWidget {
  const OperationsScroll({
    super.key,
    required this.controller,
    required this.children,
  });
  final Stage1Controller controller;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => PullToRefresh(
    controller: controller,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        OperationsStatus(controller: controller),
        if (controller.operationsView.ready) ...children,
      ],
    ),
  );
}

class OperationsOverview extends StatelessWidget {
  const OperationsOverview({super.key, required this.controller});
  final Stage1Controller controller;
  @override
  Widget build(BuildContext context) {
    final c = controller, o = c.operationsView;
    if (!o.ready) return const SizedBox();
    if (c.selectedTrip?.importMetadata.isNotEmpty ?? false) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              const Text(
                'Исторический выезд из Excel',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const Text(
                'Пустые оплаты не считаются подтверждённой задолженностью. Расписание и поимённый состав перенесены в объёме исходных книг.',
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () =>
                        DefaultTabController.of(context).animateTo(1),
                    child: const Text('Участники'),
                  ),
                  OutlinedButton(
                    onPressed: () =>
                        DefaultTabController.of(context).animateTo(2),
                    child: const Text('Платежи'),
                  ),
                  OutlinedButton(
                    onPressed: () =>
                        DefaultTabController.of(context).animateTo(3),
                    child: const Text('Рассадка из Excel'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final people = c.peopleView.participations
        .where(
          (p) =>
              p.role == 'client' &&
              (p.requestedStatus ?? p.status) == 'confirmed',
        )
        .toList();
    final water = o.unassigned(c.peopleView).length;
    final out = people
        .where(
          (p) => ![
            'self',
            'bus',
          ].contains(o.journey('participant', p.id, 'outbound')?['mode']),
        )
        .length;
    final back = people
        .where(
          (p) => ![
            'self',
            'bus',
          ].contains(o.journey('participant', p.id, 'return')?['mode']),
        )
        .length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Text(
              'Готовность к выезду',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () =>
                      DefaultTabController.of(context).animateTo(3),
                  child: Text('Байдарки · без места $water'),
                ),
                OutlinedButton(
                  onPressed: () =>
                      DefaultTabController.of(context).animateTo(5),
                  child: Text('Трансфер · не указан: туда $out, обратно $back'),
                ),
                OutlinedButton(
                  onPressed: () =>
                      DefaultTabController.of(context).animateTo(6),
                  child: Text(
                    'Инструкторы · ${o.instructorsOnWater(c.peopleView)}/${o.requiredInstructors(c.peopleView)}',
                  ),
                ),
              ],
            ),
            if (o.issues(c.peopleView).isNotEmpty)
              const Text(
                'Есть расхождения фактического присутствия с планом. Проверьте разделы выезда.',
                style: TextStyle(color: Color(0xffa53c30)),
              ),
          ],
        ),
      ),
    );
  }
}
