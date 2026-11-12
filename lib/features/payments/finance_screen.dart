import 'package:flutter/material.dart';
import '../../core/prototype.dart';
import '../../app/sync_widgets.dart';
import '../trips/trip_format.dart';
import 'payment_editor.dart';

class FinanceScreen extends StatefulWidget {
  const FinanceScreen({super.key, required this.controller});
  final Stage1Controller controller;
  @override
  State<FinanceScreen> createState() => _FinanceScreenState();
}

class _FinanceScreenState extends State<FinanceScreen> {
  String? _selected;
  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Проверьте данные или разберите предыдущее изменение компании.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _payment(
    Booking booking,
    PaymentMode mode, [
    PaymentEntry? source,
  ]) async {
    final result = await showDialog<JsonMap>(
      context: context,
      builder: (dialogContext) => _scoped(
        dialogContext,
        booking.tripId,
        PaymentEditor(
          controller: widget.controller,
          booking: booking,
          mode: mode,
          source: source,
        ),
      ),
    );
    if (result != null) {
      await _perform(
        () => widget.controller.queueFinance(
          result['kind'] as String,
          result['payload'] as JsonMap,
          expectedVersion: result['version'] as int,
        ),
      );
    }
  }

  Future<void> _prices(Booking booking, List<Participation> people) async {
    final result = await showDialog<JsonMap>(
      context: context,
      builder: (dialogContext) => _scoped(
        dialogContext,
        booking.tripId,
        PriceEditor(people: people, view: widget.controller.peopleView),
      ),
    );
    if (result != null) {
      await _perform(
        () => widget.controller.queueFinance('set_prices', {
          ...result,
          'booking_id': booking.id,
        }),
      );
    }
  }

  Widget _scoped(BuildContext dialogContext, String tripId, Widget child) =>
      ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          if (c.selectedTripId == tripId &&
              c.trips.any((t) => t.id == tripId)) {
            return child;
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (dialogContext.mounted &&
                ModalRoute.of(dialogContext)?.isCurrent == true) {
              Navigator.pop(dialogContext);
            }
          });
          return const AlertDialog(
            title: Text('Выезд недоступен'),
            content: Text('Доступ изменился. Финансовая форма закрыта.'),
          );
        },
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller,
          f = c.financeView,
          view = c.peopleView,
          trip = c.selectedTrip;
      if (trip == null) return const SizedBox();
      final bookings = view.bookings
          .where(
            (b) =>
                b.data['legacy'] != true &&
                (!view.participations.any(
                      (p) => p.bookingId == b.id && p.role == 'instructor',
                    ) ||
                    view.participations.any(
                      (p) => p.bookingId == b.id && p.role == 'client',
                    )),
          )
          .toList();
      if (!bookings.any((b) => b.id == _selected)) {
        _selected = bookings.firstOrNull?.id;
      }
      final booking = bookings.where((b) => b.id == _selected).firstOrNull;
      final people = view.participations
          .where((p) => p.bookingId == booking?.id)
          .toList();
      final cost = people.fold(0, (sum, p) => sum + p.priceKopecks),
          net = booking == null ? 0 : f.net(booking.id),
          credited = people.fold<int>(0, (sum, p) => sum + f.credited(p.id)),
          balance =
              cost -
              credited -
              (booking == null ? 0 : f.unallocated(booking.id));
      final incompletePayments = people.any(
        (p) => p.data['import_metadata']?['payment_recorded'] == false,
      );
      return PullToRefresh(
        controller: c,
        child: ListView(
          padding: const EdgeInsets.all(16),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (trip.importMetadata.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Здесь учтены только платежи из заполненных исходных колонок Excel. Пустые ячейки означают отсутствие сведений об оплате.',
                ),
              ),
            const SizedBox(height: 16),
            if (!f.ready)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Платежи ещё не загружены. При наличии связи данные появятся автоматически.',
                ),
              )
            else if (booking == null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Text(
                      'Пока нет компаний. Добавьте участников, чтобы вести оплату.',
                    ),
                    TextButton(
                      onPressed: () =>
                          DefaultTabController.of(context).animateTo(1),
                      child: const Text('К участникам'),
                    ),
                  ],
                ),
              )
            else ...[
              DropdownButtonFormField<String>(
                key: ValueKey(_selected),
                initialValue: _selected,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Компания'),
                items: [
                  for (final b in bookings)
                    DropdownMenuItem(
                      value: b.id,
                      child: Text(
                        '${b.contactName} · ${view.participations.where((p) => p.bookingId == b.id && p.role == 'client').length} чел.',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _selected = v),
              ),
              const SizedBox(height: 16),
              if (f.provisional ||
                  booking.pending ||
                  people.any((p) => p.pending))
                Container(
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.only(bottom: 16),
                  color: const Color(0xfffff4d6),
                  child: Text(
                    'Предварительные суммы: есть локальные изменения. Чистая оплата на сервере ${moneyText(f.serverNet(booking.id))}. Итог подтвердит сервер после обмена.',
                  ),
                ),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _sum('Стоимость', cost),
                  _sum('Получено', f.received(booking.id)),
                  _sum('Возвращено', f.refunded(booking.id)),
                  _sum(
                    incompletePayments
                        ? 'Остаток неизвестен'
                        : balance < 0
                        ? 'Переплата'
                        : 'Осталось оплатить',
                    incompletePayments ? null : balance.abs(),
                    accent: balance != 0,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Чистая оплата ${moneyText(net)} · зачтено участникам ${moneyText(credited)} · не распределено ${moneyText(f.unallocated(booking.id))}',
                ),
              ),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: () => _payment(booking, PaymentMode.income),
                    icon: const Icon(Icons.add),
                    label: const Text('Получить оплату'),
                  ),
                  OutlinedButton.icon(
                    onPressed: net > 0
                        ? () => _payment(booking, PaymentMode.refund)
                        : null,
                    icon: const Icon(Icons.undo),
                    label: const Text('Записать возврат'),
                  ),
                  OutlinedButton(
                    onPressed: () => _prices(booking, people),
                    child: const Text('Изменить стоимость'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              for (final command in f.commands.where(
                (cmd) =>
                    cmd.error != null &&
                    cmd.payload['booking_id'] == booking.id,
              ))
                _conflict(command),
              Text(
                'Расчёт по участникам',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              for (final p in people)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          view.person(p.personId)?.name ?? 'Участник',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${participationLabel(p.status)}${p.role == 'instructor' ? ' · инструктор' : ''}',
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 16,
                          runSpacing: 6,
                          children: [
                            Text('Стоимость ${moneyText(p.priceKopecks)}'),
                            Text('Зачтено ${moneyText(f.credited(p.id))}'),
                            Text(
                              p.priceKopecks - f.credited(p.id) < 0
                                  ? 'Переплата ${moneyText(f.credited(p.id) - p.priceKopecks)}'
                                  : 'Остаток ${moneyText(p.priceKopecks - f.credited(p.id))}',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: p.priceKopecks - f.credited(p.id) > 0
                                    ? const Color(0xff875c00)
                                    : const Color(0xff087b77),
                              ),
                            ),
                          ],
                        ),
                        if (p.status == 'cancelled')
                          const Text(
                            'Отмена участия сохраняет стоимость. Для изменения используйте действие выше.',
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              Text(
                'Платежи и корректировки',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              if (f.forBooking(booking.id).isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Платежей по компании пока нет.'),
                ),
              for (final payment in f.forBooking(booking.id).reversed)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 8,
                      children: [
                        Text(
                          '${payment.label} · ${moneyText(payment.signedKopeks)}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${payment.data['source_date_unknown'] == true ? 'Дата получения в Excel не указана' : tripDate(payment.occurredAt, trip.timeZone)} · ${paymentMethod(payment.method)}',
                        ),
                        if (payment.pending)
                          Text(
                            payment.conflict
                                ? 'Требует решения'
                                : 'Сохранено на устройстве · ожидает подтверждения',
                          ),
                        if (f.reversed(payment.id))
                          const Text(
                            'Исправлен: влияние исходной записи отменено корректировкой.',
                          ),
                        if (payment.direction == 'reversal')
                          const Text(
                            'Сторно ошибочной записи. Не является фактическим возвратом денег.',
                          ),
                        if (payment.correctionOf != null)
                          const Text(
                            'Верный вариант ранее исправленного платежа',
                          ),
                        if (payment.notes.isNotEmpty) Text(payment.notes),
                        if (payment.reason.isNotEmpty)
                          Text('Причина · ${payment.reason}'),
                        Text(
                          'Распределено ${moneyText(payment.allocated)} из ${moneyText(payment.amount)}',
                        ),
                        for (final a in payment.allocations)
                          Text(
                            '${view.person(people.where((p) => p.id == a['participation_id']).firstOrNull?.personId ?? '')?.name ?? 'Участник'} · ${moneyText(a['amount_kopeks'] as int)}',
                          ),
                        if (payment.direction != 'reversal' &&
                            !f.reversed(payment.id))
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            children: [
                              TextButton(
                                onPressed: () => _payment(
                                  booking,
                                  PaymentMode.allocate,
                                  payment,
                                ),
                                child: const Text('Распределить'),
                              ),
                              TextButton(
                                onPressed: () => _payment(
                                  booking,
                                  PaymentMode.correct,
                                  payment,
                                ),
                                child: const Text('Исправить с причиной'),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ExpansionTile(
                title: const Text('История стоимости и распределения'),
                children: [
                  for (final h in f.priceHistory.where(
                    (h) => people.any((p) => p.id == h['registration_id']),
                  ))
                    ListTile(
                      title: Text(
                        '${view.person(people.firstWhere((p) => p.id == h['registration_id']).personId)?.name ?? 'Участник'} · ${moneyText(h['old_kopeks'] as int)} → ${moneyText(h['new_kopeks'] as int)}',
                      ),
                      subtitle: Text(
                        '${h['reason']} · ${tripDate(DateTime.parse(h['created_at'] as String), trip.timeZone)}',
                      ),
                    ),
                  for (final h in f.allocationHistory.where(
                    (h) => f
                        .forBooking(booking.id)
                        .any((p) => p.id == h['payment_id']),
                  ))
                    ListTile(
                      title: Text(h['reason'] as String? ?? 'Распределение'),
                      subtitle: Text(
                        '${tripDate(DateTime.parse(h['created_at'] as String), trip.timeZone)} · верcия ${h['version']}',
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      );
    },
  );
  Widget _sum(String label, int? amount, {bool accent = false}) => SizedBox(
    width: 220,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            const SizedBox(height: 8),
            Text(
              amount == null ? '—' : moneyText(amount),
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w700,
                color: accent ? const Color(0xff875c00) : null,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget _conflict(PeopleCommand command) => Card(
    color: const Color(0xffffecee),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Text(command.label, style: Theme.of(context).textTheme.titleMedium),
          Text(financeError(command.error)),
          FutureBuilder<JsonMap?>(
            future: widget.controller.database.serverRoster(command.tripId!),
            builder: (context, snapshot) {
              final data = snapshot.data;
              if (command.kind == 'set_prices') {
                return Text(
                  (command.payload['lines'] as List)
                      .map((line) {
                        final current = (data?['participations'] as List? ?? [])
                            .where((p) => p['id'] == line['id'])
                            .firstOrNull;
                        final person = widget
                            .controller
                            .peopleView
                            .participations
                            .where((p) => p.id == line['id'])
                            .firstOrNull;
                        return '${widget.controller.peopleView.person(person?.personId ?? '')?.name ?? 'Участник'}: ваш вариант ${moneyText(line['amount_kopeks'] as int)}, на сервере ${current == null ? 'нет записи' : moneyText(current['agreed_price_kopeks'] as int)}';
                      })
                      .join('\n'),
                );
              }
              final current = (data?['payments'] as List? ?? [])
                  .where((p) => p['id'] == command.payload['id'])
                  .firstOrNull;
              return current == null
                  ? const SizedBox()
                  : Text(
                      'Исходная сумма на сервере ${moneyText(current['signed_kopeks'] as int)}',
                    );
            },
          ),
          if (command.payload['amount_kopeks'] is int)
            Text(
              'Предложенная сумма ${moneyText(command.payload['amount_kopeks'] as int)}',
            ),
          const Text(
            'Проверьте актуальные суммы перед повтором. Зависимые локальные действия при разборе будут отменены.',
          ),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => _perform(
                  () => widget.controller.retryPeopleChange(command),
                ),
                child: const Text('Повторить с текущими данными'),
              ),
              TextButton(
                onPressed: () => _perform(
                  () => widget.controller.discardPeopleChange(command.id),
                ),
                child: const Text('Отменить локальное изменение'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
