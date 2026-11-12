import '../../core/vest_sizes.dart';
import 'package:flutter/material.dart';

import '../../core/prototype_models.dart';
import '../../core/stage1_controller.dart';
import '../../core/stage1_models.dart';
import 'trip_editor.dart';
import 'trip_format.dart';
import 'trips_screen.dart' show TripStateLabel;
import '../bookings/roster_screen.dart';
import '../payments/finance_screen.dart';
import '../kayaks/kayaks_screen.dart';
import '../transport/transport_screen.dart';
import '../cabins/cabins_screen.dart';
import '../staff/staff_screen.dart';
import '../operations/operations_widgets.dart' show OperationsOverview;
import '../../app/sync_widgets.dart';
import 'trip_presentation.dart' show CapacityNotice, TripOccupancy, tripDates;
import '../../core/finance_models.dart';

class TripDetail extends StatefulWidget {
  const TripDetail({super.key, required this.controller});
  final Stage1Controller controller;

  @override
  State<TripDetail> createState() => _TripDetailState();
}

class _TripDetailState extends State<TripDetail> {
  Future<void> _perform(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось выполнить действие. Проверьте состояние обмена и повторите попытку.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _edit(Trip trip) async {
    final draft = await showDialog<TripDraft>(
      context: context,
      builder: (_) => TripEditor(
        teams: widget.controller.teams,
        routes: widget.controller.routes,
        trip: trip,
      ),
    );
    if (draft != null) {
      await _perform(() async {
        await widget.controller.saveTrip(draft, tripId: trip.id);
      });
    }
  }

  Future<void> _add() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _ParticipantDialog(),
    );
    if (name != null) {
      await _perform(() => widget.controller.addParticipant(name));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final trip = controller.selectedTrip;
        return SyncRefreshScope(
          controller: controller,
          child: DefaultTabController(
            length: controller.hasPeople ? 7 : 2,
            child: Scaffold(
              appBar: AppBar(
                toolbarHeight: syncToolbarHeight(context),
                title: SyncPageTitle(
                  title: trip?.title ?? 'Выезд недоступен',
                  controller: controller,
                ),
                actions: [RefreshAction(controller: controller)],
                bottom: trip == null
                    ? null
                    : TabBar(
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        tabs: [
                          const Tab(text: 'Обзор'),
                          const Tab(text: 'Участники'),
                          if (controller.hasPeople) const Tab(text: 'Оплаты'),
                          if (controller.hasPeople) const Tab(text: 'Байдарки'),
                          if (controller.hasPeople) const Tab(text: 'Домики'),
                          if (controller.hasPeople) const Tab(text: 'Трансфер'),
                          if (controller.hasPeople)
                            const Tab(text: 'Работники'),
                        ],
                      ),
              ),
              body: trip == null
                  ? const Center(
                      child: Text(
                        'Выезд удалён из доступных данных. Вернитесь к списку.',
                      ),
                    )
                  : TabBarView(
                      children: [
                        _overview(context, trip),
                        controller.hasPeople
                            ? RosterScreen(controller: controller)
                            : _participants(context, trip),
                        if (controller.hasPeople)
                          FinanceScreen(controller: controller),
                        if (controller.hasPeople)
                          KayaksScreen(controller: controller),
                        if (controller.hasPeople)
                          CabinsScreen(controller: controller),
                        if (controller.hasPeople)
                          TransportScreen(controller: controller),
                        if (controller.hasPeople)
                          StaffScreen(controller: controller),
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _scroll({required Widget child}) => PullToRefresh(
    controller: widget.controller,
    child: _DetailScroll(child: child),
  );

  Widget _overview(BuildContext context, Trip trip) {
    final controller = widget.controller;
    final theme = Theme.of(context);
    final editable =
        trip.syncState == TripSyncState.synced &&
        !['completed', 'cancelled'].contains(trip.status);
    final members = controller.peopleView.participations
        .where((p) => p.status != 'cancelled' && p.role == 'client')
        .toList();
    final sizes = <String, int>{};
    for (final p in members) {
      final size = vestSize(p.parameters['clothing_size']);
      sizes[size] = (sizes[size] ?? 0) + 1;
    }
    return _scroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${members.length} участников · ${controller.operationsView.bookings('boat').length} байдарок',
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text('Начало: ${tripDate(trip.startsAt, trip.timeZone)}'),
                  Text('Окончание: ${tripDate(trip.endsAt, trip.timeZone)}'),
                  const SizedBox(height: 8),
                  const Tooltip(
                    message: vestSizeGuide,
                    child: Text('Спасжилеты по размерам ⓘ'),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final e in sizes.entries)
                        Chip(label: Text('${e.key}: ${e.value}')),
                    ],
                  ),
                ],
              ),
            ),
          ),
          CapacityNotice(
            trip: trip,
            value: TripOccupancy.read(controller, trip),
          ),
          OperationsOverview(controller: controller),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TripStateLabel(trip: trip),
                  const SizedBox(height: 16),
                  Text(trip.route, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    '${tripDates(trip)} · ${trip.dateOnly ? 'время не указано' : 'старт ${tripDate(trip.startsAt, trip.timeZone).split(' ').last}'}',
                  ),
                  Text(
                    'Часовой пояс · ${trip.timeZone}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    trip.dateOnly
                        ? 'Место и время сбора в Excel не указаны'
                        : 'Сбор · ${tripDate(trip.meetingAt, trip.timeZone)}',
                  ),
                  if (trip.meetingPoint.isNotEmpty) Text(trip.meetingPoint),
                  if (trip.responsibleNames.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text('Ответственные · ${trip.responsibleNames}'),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    trip.capacityKnown
                        ? 'Лимит клиентов · ${trip.capacity}'
                        : 'Лимит клиентов в источнике не указан',
                  ),
                  if (controller.financeView.ready) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Чистая оплата · ${moneyText(controller.financeView.net(null))}',
                    ),
                    Text(
                      'Остаток по выезду · ${moneyText(controller.peopleView.participations.where((p) => p.data['legacy'] != true).fold(0, (sum, p) => sum + p.priceKopecks) - controller.financeView.net(null))}',
                    ),
                    if (controller.financeView.provisional)
                      const Text('Суммы предварительные · ожидают сервера'),
                  ],
                  Text(
                    'Базовая стоимость · ${trip.basePriceKopecks ~/ 100},${(trip.basePriceKopecks % 100).toString().padLeft(2, '0')} ₽',
                  ),
                  if (trip.isDownloaded) ...[
                    const SizedBox(height: 12),
                    Text('Подтверждено · ${controller.selectedConfirmedCount}'),
                    if (controller.hasPeople) ...[
                      Text(
                        'Инструкторов · ${controller.peopleView.instructorCount}',
                      ),
                      Text(
                        'Лист ожидания · ${controller.peopleView.participations.where((p) => p.role == 'client' && p.status == 'waiting').length}',
                      ),
                    ],
                    Text(
                      'Ожидают подтверждения · ${controller.selectedPendingCount}',
                    ),
                    if (trip.capacityKnown)
                      Text(
                        'Свободно по лимиту · ${(trip.capacity - controller.selectedConfirmedCount).clamp(0, trip.capacity)}',
                      ),
                  ],
                  if (trip.notes.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(trip.notes),
                    ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: editable ? () => _edit(trip) : null,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Изменить выезд'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    trip.isDownloaded
                        ? 'Данные выезда доступны без связи.'
                        : 'Состав загрузится автоматически при наличии связи.',
                  ),
                  if (trip.lastSyncedAt != null)
                    Text(
                      'Последний обмен · ${tripDate(trip.lastSyncedAt!, trip.timeZone)}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
          if (trip.syncState == TripSyncState.pending)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Изменения сохранены на устройстве. Следующее редактирование станет доступно после подтверждения сервером.',
              ),
            ),
          if (trip.syncState == TripSyncState.conflict)
            _ConflictCard(
              trip: trip,
              onEdit: () => _edit(trip),
              onRetry: () => _perform(() => controller.retryConflict(trip.id)),
              onDiscard: () =>
                  _perform(() => controller.discardConflict(trip.id)),
            ),
        ],
      ),
    );
  }

  Widget _participants(BuildContext context, Trip trip) {
    final controller = widget.controller;
    if (!trip.isDownloaded) {
      return _scroll(
        child: const Text('Состав загрузится автоматически при наличии связи.'),
      );
    }
    return _scroll(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                trip.capacityKnown
                    ? 'Подтверждено ${controller.selectedConfirmedCount} из ${trip.capacity}'
                    : 'Подтверждено ${controller.selectedConfirmedCount} · лимит не указан',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              FilledButton.icon(
                onPressed: trip.status == 'open' ? _add : null,
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Добавить участника'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (trip.status != 'open')
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Добавление участников доступно при открытой записи.',
              ),
            ),
          if (controller.selectedParticipants.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'В составе пока никого нет. Добавьте первого участника.',
              ),
            ),
          for (final participant in controller.selectedParticipants)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      participant.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(switch (participant.status) {
                          ParticipantStatus.confirmed =>
                            Icons.check_circle_outline,
                          ParticipantStatus.pending => Icons.schedule,
                          ParticipantStatus.rejected => Icons.error_outline,
                        }, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(switch (participant.status) {
                            ParticipantStatus.confirmed => 'Подтверждено',
                            ParticipantStatus.pending =>
                              'Ожидает подтверждения сервера',
                            ParticipantStatus.rejected =>
                              participant.reason == 'capacity_reached'
                                  ? 'Свободных мест больше нет. Запись требует решения.'
                                  : 'Запись требует решения.',
                          }),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({
    required this.trip,
    required this.onEdit,
    required this.onRetry,
    required this.onDiscard,
  });
  final Trip trip;
  final VoidCallback onEdit;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  String _summary(Trip value) =>
      '${value.title}\n${value.route}\n'
      '${tripDate(value.startsAt, value.timeZone)} — ${tripDate(value.endsAt, value.timeZone)} · ${value.timeZone}\n'
      'Сбор ${tripDate(value.meetingAt, value.timeZone)} · ${value.meetingPoint}\n'
      'Ответственные · ${value.responsibleNames}\n'
      'Лимит ${value.capacity} · ${tripStatusLabel(value.status)}\n'
      'Стоимость ${(value.basePriceKopecks / 100).toStringAsFixed(2)} ₽\n'
      '${value.notes}';
  @override
  Widget build(BuildContext context) {
    final server = trip.serverTrip;
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Изменения требуют решения',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(conflictReasonLabel(trip.conflictReason)),
            const SizedBox(height: 16),
            Text('Ваш вариант\n${_summary(trip)}'),
            if (server != null) ...[
              const SizedBox(height: 12),
              Text('На сервере\n${_summary(server)}'),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (server != null && trip.conflictReason == 'version_conflict')
                  FilledButton(
                    onPressed: onRetry,
                    child: const Text('Применить мой вариант'),
                  ),
                if (server != null &&
                    !['completed', 'cancelled'].contains(server.status))
                  OutlinedButton(
                    onPressed: onEdit,
                    child: const Text('Исправить мой вариант'),
                  ),
                OutlinedButton(
                  onPressed: onDiscard,
                  child: Text(
                    server == null
                        ? 'Удалить локальный черновик'
                        : 'Принять серверный вариант',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailScroll extends StatelessWidget {
  const _DetailScroll({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.all(16),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: child,
      ),
    ),
  );
}

class _ParticipantDialog extends StatefulWidget {
  const _ParticipantDialog();
  @override
  State<_ParticipantDialog> createState() => _ParticipantDialogState();
}

class _ParticipantDialogState extends State<_ParticipantDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (_form.currentState?.validate() ?? false) {
      Navigator.pop(context, _name.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Новая запись'),
    scrollable: true,
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _name,
        autofocus: true,
        maxLength: 100,
        decoration: const InputDecoration(labelText: 'Имя и фамилия'),
        validator: (v) => (v ?? '').trim().isEmpty ? 'Введите имя' : null,
        onFieldSubmitted: (_) => _save(),
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
