import '../../core/company_color.dart';
import 'package:flutter/material.dart';
import '../../core/prototype.dart';
import '../people/people_conflicts.dart';
import '../payments/payment_editor.dart';
import '../trips/trip_format.dart';
import '../../app/sync_widgets.dart';
import '../trips/trip_presentation.dart';
import 'booking_editor.dart';
import 'participation_editor.dart';

class RosterScreen extends StatefulWidget {
  const RosterScreen({super.key, required this.controller});
  final Stage1Controller controller;
  @override
  State<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends State<RosterScreen> {
  String _search = '';
  String _rosterSection = 'active';

  Widget _rosterTabs() => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      for (final (value, label) in [
        ('active', 'Состав'),
        ('waiting', 'Резерв'),
        ('cancelled', 'Список отмены'),
      ])
        ChoiceChip(
          label: Text(label),
          selected: _rosterSection == value,
          onSelected: (_) => setState(() => _rosterSection = value),
        ),
    ],
  );

  Widget _inactiveRoster(Trip trip, PeopleView view) {
    final reserve = _rosterSection == 'waiting';
    final entries = view.participations
        .where(
          (p) =>
              p.role == 'client' &&
              (p.requestedStatus ?? p.status) == _rosterSection,
        )
        .toList();
    if (reserve) {
      entries.sort((a, b) {
        final order = (a.waitingAt ?? DateTime.utc(2100)).compareTo(
          b.waitingAt ?? DateTime.utc(2100),
        );
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
    }
    final companies = {
      for (final booking in view.bookings) booking.id: booking,
    };
    return PullToRefresh(
      controller: widget.controller,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: entries.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                _rosterTabs(),
                PeopleConflicts(controller: widget.controller, tripId: trip.id),
                if (entries.isEmpty)
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        reserve
                            ? 'В резерве пока никого нет.'
                            : 'Отменённых участий пока нет.',
                      ),
                    ),
                  ),
              ],
            );
          }
          final p = entries[index - 1];
          final company = companies[p.bookingId];
          final person = view.person(p.personId);
          final theme = Theme.of(context);
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (company != null)
                  Container(
                    color: companyColor(company.id),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Text(
                      company.contactName,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final info = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 4,
                        children: [
                          Text(
                            person?.name ?? 'Участник',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (person?.phone.isNotEmpty ?? false)
                            SelectableText(
                              person!.phone,
                              style: theme.textTheme.bodySmall,
                            ),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              _Badge(
                                label: reserve
                                    ? 'Место в очереди · $index'
                                    : 'Отменено',
                                color: reserve
                                    ? const Color(0xff946300)
                                    : theme.colorScheme.error,
                              ),
                              if (p.pending)
                                _PendingBadge(conflict: p.conflict),
                            ],
                          ),
                        ],
                      );
                      if (p.data['legacy'] == true || trip.status != 'open') {
                        return info;
                      }
                      final actions = Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _QuickButton(
                            label: 'Вернуть',
                            onPressed: p.pending ? null : () => _restore(p),
                          ),
                          if (reserve)
                            IconButton(
                              tooltip: 'Перенести на другой выезд',
                              onPressed: p.pending ? null : () => _move(p),
                              icon: const Icon(Icons.event_repeat_outlined),
                            ),
                        ],
                      );
                      if (constraints.maxWidth < 320 ||
                          MediaQuery.textScalerOf(context).scale(16) > 20) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 8,
                          children: [info, actions],
                        );
                      }
                      return Row(
                        spacing: 12,
                        children: [
                          Expanded(child: info),
                          actions,
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _restore(Participation participant) async {
    final separate = await showDialog<bool>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('Вернуть в состав'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('В свою компанию'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Отдельным участником'),
          ),
        ],
      ),
    );
    if (separate == null ||
        !mounted ||
        widget.controller.selectedTripId != participant.tripId) {
      return;
    }
    await _action(
      () => widget.controller.setParticipationStatus(
        {participant.id},
        'confirmed',
        separate: separate,
      ),
    );
  }

  Future<void> _move(Participation participant) async {
    final c = widget.controller;
    final source = c.selectedTrip;
    if (source == null) return;
    final target = await chooseDestinationTrip(
      context,
      c.trips.where(
        (t) =>
            t.id != source.id &&
            t.teamId == source.teamId &&
            t.version > 0 &&
            t.status == 'open',
      ),
      title: 'Перенести участника',
      detail:
          'Выберите выезд на новую дату. Запись и платежи по прежнему выезду сохранятся в его истории.',
    );
    if (target != null && mounted) {
      await _action(() => c.moveParticipant(participant, target));
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Сначала разрешите конфликт предыдущего изменения или проверьте данные.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _booking([Booking? booking]) async {
    final result = await showDialog<BookingFormResult>(
      context: context,
      builder: (_) =>
          BookingEditor(controller: widget.controller, booking: booking),
    );
    if (result != null) {
      await _action(
        () => widget.controller.saveBooking(
          result.payload,
          newPeople: result.newPeople,
          previous: booking,
        ),
      );
    }
  }

  Future<void> _parameters(Participation person) async {
    final result = await showDialog<JsonMap>(
      context: context,
      builder: (_) => ParticipationEditor(
        name:
            widget.controller.peopleView.person(person.personId)?.name ??
            'Участник',
        role: person.role,
        parameters: person.parameters,
      ),
    );
    if (result != null) {
      await _action(
        () => widget.controller.editParticipation(
          person,
          role: result['role'] as String,
          parameters: result['parameters'] as JsonMap,
        ),
      );
    }
  }

  Future<void> _remove(Participation participant, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Удалить со сплава?'),
        content: Text(name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _action(
        () => widget.controller.setParticipationStatus({
          participant.id,
        }, 'cancelled'),
      );
    }
  }

  Future<void> _history(Participation participant) async {
    final trip = widget.controller.selectedTrip!;
    final roster = await widget.controller.database.serverRoster(trip.id);
    final history = (roster?['history'] as List? ?? [])
        .where((h) => h['registration_id'] == participant.id)
        .toList();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('История участия'),
        scrollable: true,
        content: SizedBox(
          width: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              if (history.isEmpty)
                const Text('История появится после синхронизации.'),
              for (final h in history)
                Text(
                  '${tripDate(DateTime.parse(h['changed_at'] as String), trip.timeZone)}\n'
                  '${h['from_status'] == null ? 'Создано' : participationLabel(h['from_status'] as String)} → '
                  '${participationLabel(h['to_status'] as String)}'
                  '${h['to_role'] == 'instructor' ? ' · инструктор' : ' · клиент'}',
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
  }

  bool _paymentOpen = false;
  String _paymentFilter = 'all';

  Future<void> _payment(
    Booking booking,
    Map<String, int> amounts,
    String heading,
  ) async {
    if (_paymentOpen) return;
    _paymentOpen = true;
    try {
      final c = widget.controller;
      final result = await showDialog<JsonMap>(
        context: context,
        builder: (dialogContext) => ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            if (c.selectedTripId != booking.tripId ||
                !c.trips.any((t) => t.id == booking.tripId)) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (dialogContext.mounted &&
                    ModalRoute.of(dialogContext)?.isCurrent == true) {
                  Navigator.pop(dialogContext);
                }
              });
              return const AlertDialog(title: Text('Выезд недоступен'));
            }
            return PaymentEditor(
              controller: c,
              booking: booking,
              mode: PaymentMode.income,
              initialAllocations: amounts,
              heading: heading,
            );
          },
        ),
      );
      if (result != null && c.selectedTripId == booking.tripId) {
        await _action(
          () => c.queueFinance(
            result['kind'] as String,
            result['payload'] as JsonMap,
            expectedVersion: result['version'] as int,
          ),
        );
      }
    } finally {
      _paymentOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller,
          view = c.peopleView,
          f = c.financeView,
          trip = c.selectedTrip;
      if (trip == null) return const SizedBox();
      if (!view.ready) {
        return PullToRefresh(
          controller: c,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                c.isOffline
                    ? 'Состав ещё не сохранён на устройстве. Он загрузится автоматически, когда появится связь.'
                    : 'Загружаем состав выезда автоматически…',
              ),
            ],
          ),
        );
      }
      final editable = !['completed', 'cancelled'].contains(trip.status);
      if (_rosterSection != 'active') {
        return _inactiveRoster(trip, view);
      }
      final credits = participantCredits(f);
      final all = <String, List<Participation>>{};
      for (final p in view.participations.where((p) => p.role == 'client')) {
        all.putIfAbsent(p.bookingId, () => []).add(p);
      }
      final query = _search.trim().toLowerCase().replaceAll('ё', 'е');
      final visible = <String, List<Participation>>{};
      for (final b in view.bookings) {
        for (final p in all[b.id] ?? <Participation>[]) {
          final person = view.person(p.personId);
          final text = [
            person?.name,
            person?.phone,
            b.contactName,
            b.phone,
          ].join(' ').toLowerCase().replaceAll('ё', 'е');
          final balance = ParticipantBalance(
            p.priceKopecks,
            credits[p.id] ?? 0,
          );
          if (![
                'waiting',
                'cancelled',
              ].contains(p.requestedStatus ?? p.status) &&
              (_paymentFilter == 'all' ||
                  (f.ready &&
                      (p.data['import_metadata']?['payment_recorded'] !=
                              false ||
                          (credits[p.id] ?? 0) > 0) &&
                      balance.state == _paymentFilter)) &&
              text.contains(query)) {
            visible.putIfAbsent(b.id, () => []).add(p);
          }
        }
      }
      final bookings = view.bookings
          .where((b) => visible.containsKey(b.id))
          .toList();
      return LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth >= 1180 &&
              MediaQuery.textScalerOf(context).scale(16) <= 20;
          return PullToRefresh(
            controller: c,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              itemCount: bookings.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _rosterTabs(),
                      CapacityNotice(
                        trip: trip,
                        value: TripOccupancy.read(c, trip),
                      ),
                      PeopleConflicts(controller: c, tripId: trip.id),
                      if (f.commands.any((v) => v.error != null))
                        Card(
                          color: const Color(0xffffeeee),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Платёж требует решения. Показаны предварительные суммы на устройстве.',
                                ),
                                TextButton(
                                  onPressed: () => DefaultTabController.of(
                                    context,
                                  ).animateTo(2),
                                  child: const Text(
                                    'Разобрать изменение в оплатах',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            'Участников ${view.participations.where((p) => !['waiting', 'cancelled'].contains(p.requestedStatus ?? p.status) && p.role == 'client').length} · ориентир ${trip.capacity} · инструкторов ${view.instructorCount}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          FilledButton.icon(
                            onPressed: trip.status == 'open'
                                ? () => _booking()
                                : null,
                            icon: const Icon(Icons.group_add_outlined),
                            label: const Text('Новая компания'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text('Оплата:'),
                          for (final filter in const {
                            'all': 'Любая',
                            'unpaid': 'Нет предоплаты',
                            'deposit': 'Есть предоплата',
                            'full': 'Оплачено полностью',
                          }.entries)
                            ChoiceChip(
                              label: Text(filter.value),
                              selected: _paymentFilter == filter.key,
                              onSelected: !f.ready && filter.key != 'all'
                                  ? null
                                  : (_) => setState(
                                      () => _paymentFilter = filter.key,
                                    ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        decoration: const InputDecoration(
                          labelText: 'Поиск участника, компании или телефона',
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => _search = v),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'Найдено участников: ${visible.values.fold<int>(0, (n, p) => n + p.length)} · компаний: ${bookings.length}. Итоги компании включают весь её состав.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      if (bookings.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Участников по выбранным условиям нет.'),
                        ),
                    ],
                  );
                }
                final b = bookings[index - 1],
                    members = all[b.id]!,
                    shown = visible[b.id]!;
                final total = members.fold<int>(
                      0,
                      (sum, p) => sum + p.priceKopecks,
                    ),
                    paid =
                        f.unallocated(b.id) +
                        members.fold<int>(
                          0,
                          (sum, p) => sum + (credits[p.id] ?? 0),
                        );
                final legacy = b.data['legacy'] == true;
                final deposit = quickPaymentAmounts(
                  members,
                  credits,
                  deposit: true,
                );
                final due = quickPaymentAmounts(
                  members,
                  credits,
                  deposit: false,
                );
                final canPay = editable && f.ready && !legacy;
                final incompletePayments = members.any(
                  (p) =>
                      p.data['import_metadata']?['payment_recorded'] == false,
                );
                final allocated = f.unallocated(b.id) == 0;
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        color: companyColor(b.id),
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 8,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${b.contactName} · ${members.length} чел.',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                      if (b.phone.isNotEmpty)
                                        SelectableText(b.phone),
                                      if (b.notes.isNotEmpty) Text(b.notes),
                                      if (b.pending)
                                        Text(
                                          b.conflict
                                              ? 'Требует решения'
                                              : 'Сохранено на устройстве',
                                          style: TextStyle(
                                            color: b.conflict
                                                ? const Color(0xffb13434)
                                                : const Color(0xff946300),
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                if (editable && !legacy)
                                  IconButton(
                                    tooltip: 'Изменить компанию',
                                    onPressed: () => _booking(b),
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 20,
                                    ),
                                  ),
                              ],
                            ),
                            Wrap(
                              spacing: 20,
                              runSpacing: 8,
                              children: [
                                _Total(
                                  label: 'Всего',
                                  amount: total,
                                  moneyReady: f.ready,
                                ),
                                _Total(
                                  label: incompletePayments
                                      ? 'Учтено оплат'
                                      : 'Оплачено',
                                  amount: paid,
                                  moneyReady: f.ready,
                                  color: const Color(0xff087c53),
                                ),
                                _Total(
                                  label: incompletePayments
                                      ? 'Остаток неизвестен'
                                      : paid > total
                                      ? 'Переплата'
                                      : 'Остаток',
                                  amount: (total - paid).abs(),
                                  moneyReady: f.ready && !incompletePayments,
                                  color: paid < total
                                      ? const Color(0xffa53c30)
                                      : const Color(0xff087c53),
                                ),
                                if (f.ready && f.unallocated(b.id) != 0)
                                  _Total(
                                    label: 'Не распределено',
                                    amount: f.unallocated(b.id),
                                    color: const Color(0xff946300),
                                  ),
                              ],
                            ),
                            if (f.commands.any(
                              (v) => v.payload['booking_id'] == b.id,
                            ))
                              const Text(
                                'Есть суммы на устройстве, ожидающие подтверждения сервера.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xff946300),
                                ),
                              ),
                            if (!f.ready)
                              const Text(
                                'Оплата ещё не загружена. Итоги появятся после обмена.',
                              ),
                            if (f.ready && !allocated)
                              TextButton(
                                onPressed: () => DefaultTabController.of(
                                  context,
                                ).animateTo(2),
                                child: const Text(
                                  'Сначала распределите полученную оплату в разделе «Оплаты»',
                                ),
                              ),
                            if (canPay)
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  _QuickButton(
                                    label: 'Предоплата · 500 ₽/чел.',
                                    onPressed:
                                        allocated &&
                                            deposit.values.any((v) => v > 0)
                                        ? () => _payment(
                                            b,
                                            deposit,
                                            'Предоплата компании',
                                          )
                                        : null,
                                  ),
                                  _QuickButton(
                                    label: 'Оплатить остаток',
                                    onPressed:
                                        allocated &&
                                            due.values.any((v) => v > 0)
                                        ? () => _payment(
                                            b,
                                            due,
                                            'Оплата компании',
                                          )
                                        : null,
                                  ),
                                  _QuickButton(
                                    label: 'Своя сумма',
                                    onPressed: () =>
                                        _payment(b, due, 'Получение оплаты'),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      if (wide)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(60, 10, 16, 6),
                          child: Row(
                            children: [
                              Expanded(child: Text('Участник · параметры')),
                              SizedBox(width: 115, child: Text('Стоимость')),
                              SizedBox(width: 145, child: Text('Оплата')),
                              SizedBox(width: 115, child: Text('Остаток')),
                              SizedBox(
                                width: 204,
                                child: Text('Быстрые действия'),
                              ),
                            ],
                          ),
                        ),
                      for (final p in shown)
                        _personRow(
                          context,
                          p,
                          b,
                          credits[p.id] ?? 0,
                          wide,
                          editable,
                          f.ready,
                        ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      );
    },
  );

  Widget _personRow(
    BuildContext context,
    Participation p,
    Booking booking,
    int paid,
    bool wide,
    bool editable,
    bool moneyReady,
  ) {
    final view = widget.controller.peopleView, person = view.person(p.personId);
    final balance = ParticipantBalance(p.priceKopecks, paid),
        legacy = p.data['legacy'] == true;
    final paidKnown =
        moneyReady &&
        (p.data['import_metadata']?['payment_recorded'] != false || paid != 0);
    final color = switch (balance.state) {
      'full' => const Color(0xff087c53),
      'deposit' => const Color(0xff946300),
      'unpaid' => const Color(0xffa53c30),
      _ => const Color(0xff587184),
    };
    final canPay =
        editable &&
        moneyReady &&
        !legacy &&
        !['cancelled', 'waiting'].contains(p.status) &&
        p.priceKopecks > 0;
    final canQuickPay =
        canPay && widget.controller.financeView.unallocated(booking.id) == 0;
    final details = [
      if (p.role == 'instructor') 'Инструктор',
      if (person?.phone.isNotEmpty ?? false) person!.phone,
      for (final e in p.parameters.entries)
        if (e.value != null && e.value.toString().isNotEmpty)
          '${_parameterLabel(e.key)}: ${e.value}',
    ].join(' · ');
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 3,
      children: [
        Text(
          person?.name ?? 'Участник',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Wrap(
          spacing: 6,
          runSpacing: 3,
          children: [
            if (p.pending) _PendingBadge(conflict: p.conflict),
            if (p.requestedStatus != null)
              _Badge(
                label: '→ ${participationLabel(p.requestedStatus!)}',
                color: const Color(0xff946300),
              ),
          ],
        ),
        if (details.isNotEmpty)
          Tooltip(
            message: details,
            child: Text(
              details,
              maxLines: wide ? 2 : null,
              overflow: wide ? TextOverflow.ellipsis : null,
              style: TextStyle(
                fontSize: 12,
                color: p.parameters['food_notes'] != null
                    ? const Color(0xff946300)
                    : const Color(0xff587184),
              ),
            ),
          ),
        if (p.status == 'waiting' && p.waitingAt != null)
          Text(
            'Место в очереди · ${view.participations.where((v) => v.status == 'waiting').toList().indexWhere((v) => v.id == p.id) + 1}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (legacy)
          Text(
            p.data['legacy_rejection'] == true
                ? 'Отклонённая запись прежней версии. Данные сохранены. ${peopleErrorLabel(p.data['reason'] as String?)}'
                : 'Запись прежней версии · ожидает обмена',
            style: const TextStyle(fontSize: 12),
          ),
      ],
    );
    final menu = PopupMenuButton<String>(
      tooltip: 'Действия участника',
      onSelected: (action) {
        if (action == 'history') _history(p);
        if (action == 'move') _move(p);
        if (action == 'reserve') {
          _action(
            () => widget.controller.setParticipationStatus({p.id}, 'waiting'),
          );
        }
        if (action == 'remove') _remove(p, person?.name ?? 'Участник');
        if (action == 'parameters') _parameters(p);
        if (action == 'custom') {
          _payment(booking, {p.id: balance.remaining}, 'Оплата участника');
        }
        if (action == 'legacy') {
          _action(() => widget.controller.retryLegacyRegistration(p));
        }
      },
      itemBuilder: (_) => [
        if (!legacy && editable && !p.pending)
          const PopupMenuItem(
            value: 'move',
            child: Text('Перенести на другой выезд'),
          ),
        if (!legacy &&
            !p.pending &&
            widget.controller.selectedTrip?.status == 'open')
          const PopupMenuItem(value: 'reserve', child: Text('В резерв')),
        if (!legacy &&
            editable &&
            (p.requestedStatus ?? p.status) != 'cancelled')
          const PopupMenuItem(
            value: 'remove',
            child: Text('Удалить со сплава'),
          ),
        if (canPay)
          const PopupMenuItem(
            value: 'custom',
            child: Text('Указать сумму оплаты'),
          ),
        if (!legacy)
          const PopupMenuItem(
            value: 'history',
            child: Text('История участника'),
          ),
        if (!legacy && editable)
          const PopupMenuItem(
            value: 'parameters',
            child: Text('Параметры на выезд'),
          ),
        if (editable &&
            widget.controller.selectedTrip?.status == 'open' &&
            p.data['legacy_rejection'] == true)
          const PopupMenuItem(
            value: 'legacy',
            child: Text('Перенести как новую запись'),
          ),
      ],
    );
    final actions = Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (canQuickPay && balance.depositDue > 0)
          Tooltip(
            message: 'Довнести предоплату до 500 ₽ на человека',
            child: _QuickButton(
              label: wide ? '500 ₽' : 'Предоплата 500 ₽',
              onPressed: () => _payment(booking, {
                p.id: balance.depositDue,
              }, 'Предоплата участника'),
            ),
          ),
        if (canQuickPay && balance.remaining > 0)
          _QuickButton(
            label: 'Оплатить',
            onPressed: () => _payment(booking, {
              p.id: balance.remaining,
            }, 'Оплата участника'),
          ),
        if (!legacy || p.data['legacy_rejection'] == true) menu,
      ],
    );
    const check = SizedBox.shrink();
    final payment = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Badge(
          label: paidKnown
              ? balance.label
              : moneyReady
              ? 'Оплата не указана'
              : 'Нет данных',
          color: paidKnown ? color : Colors.blueGrey,
        ),
        Text(
          paidKnown ? compactMoneyText(paid) : '—',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: moneyReady ? color : Colors.blueGrey,
          ),
        ),
      ],
    );
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xffe0e7ee))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                check,
                const SizedBox(width: 4),
                Expanded(child: info),
                SizedBox(
                  width: 115,
                  child: Text(
                    moneyReady ? compactMoneyText(p.priceKopecks) : '—',
                  ),
                ),
                SizedBox(width: 145, child: payment),
                SizedBox(
                  width: 115,
                  child: Text(
                    paidKnown ? compactMoneyText(balance.remaining) : '—',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                SizedBox(width: 204, child: actions),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    check,
                    const SizedBox(width: 4),
                    Expanded(child: info),
                  ],
                ),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _Total(
                      label: 'Стоимость',
                      amount: p.priceKopecks,
                      moneyReady: moneyReady,
                    ),
                    payment,
                    _Total(
                      label: 'Остаток',
                      amount: balance.remaining,
                      moneyReady: paidKnown,
                    ),
                  ],
                ),
                if (canPay || !legacy) actions,
              ],
            ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({
    required this.label,
    required this.amount,
    this.moneyReady = true,
    this.color,
  });
  final String label;
  final int amount;
  final bool moneyReady;
  final Color? color;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      Text(
        moneyReady ? compactMoneyText(amount) : '—',
        style: TextStyle(fontWeight: FontWeight.w700, color: color),
      ),
    ],
  );
}

class _PendingBadge extends StatelessWidget {
  const _PendingBadge({required this.conflict});
  final bool conflict;

  @override
  Widget build(BuildContext context) => _Badge(
    label: conflict ? 'Требует решения' : 'На устройстве',
    color: conflict ? const Color(0xffb13434) : const Color(0xff946300),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 12, height: 1.25),
    ),
  );
}

class _QuickButton extends StatelessWidget {
  const _QuickButton({required this.label, this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => OutlinedButton(
    style: OutlinedButton.styleFrom(
      minimumSize: Size(
        0,
        Theme.of(context).platform == TargetPlatform.windows ? 32 : 40,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      visualDensity: Theme.of(context).platform == TargetPlatform.windows
          ? VisualDensity.compact
          : VisualDensity.standard,
    ),
    onPressed: onPressed,
    child: Text(label, textAlign: TextAlign.center),
  );
}

String _parameterLabel(String key) => switch (key) {
  'height_cm' => 'Рост, см',
  'weight_kg' => 'Вес, кг',
  'age_years' => 'Возраст',
  'clothing_size' => 'Размер',
  'food_notes' => 'Питание',
  'notes' => 'Примечание',
  _ => key,
};
