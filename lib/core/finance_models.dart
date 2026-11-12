import 'people_models.dart';

const financeKinds = {
  'set_prices',
  'add_payment',
  'allocate_payment',
  'correct_payment',
};

const defaultDepositKopeks = 50000;

/// Partial payment is a deposit. Full payment and free participation have their
/// own states; refunds and corrections are already included in [paid].
class ParticipantBalance {
  const ParticipantBalance(this.price, this.paid);
  final int price, paid;
  int get remaining => (price - paid).clamp(0, 1000000000000);
  int get deposit => paid > 0 && paid < price ? paid : 0;
  String get state => price == 0 && paid == 0
      ? 'free'
      : paid >= price
      ? 'full'
      : paid > 0
      ? 'deposit'
      : 'unpaid';
  String get label => switch (state) {
    'free' => 'Без оплаты',
    'full' => paid > price ? 'Переплата' : 'Оплачено',
    'deposit' => 'Предоплата',
    _ => 'Нет предоплаты',
  };
  int get depositDue => (price.clamp(0, defaultDepositKopeks) - paid).clamp(
    0,
    defaultDepositKopeks,
  );
}

/// Build once per render rather than scanning the ledger for every table cell.
Map<String, int> participantCredits(FinanceView finance) {
  final result = <String, int>{};
  for (final payment in finance.payments) {
    for (final line in payment.allocations) {
      final id = line['participation_id'] as String;
      result[id] =
          (result[id] ?? 0) +
          payment.signedKopeks.sign * (line['amount_kopeks'] as int);
    }
  }
  return result;
}

Map<String, int> quickPaymentAmounts(
  Iterable<Participation> people,
  Map<String, int> credits, {
  required bool deposit,
}) => {
  for (final p in people)
    if (p.status != 'cancelled' &&
        p.status != 'waiting' &&
        p.data['legacy'] != true &&
        p.priceKopecks > 0)
      p.id: deposit
          ? ParticipantBalance(p.priceKopecks, credits[p.id] ?? 0).depositDue
          : ParticipantBalance(p.priceKopecks, credits[p.id] ?? 0).remaining,
};
int? parseKopeks(String input) {
  final value = input
      .trim()
      .replaceAll(' ', '')
      .replaceAll('\u00a0', '')
      .replaceAll(',', '.');
  if (!RegExp(r'^\d{1,11}(\.\d{1,2})?$').hasMatch(value)) return null;
  final parts = value.split('.');
  final cents =
      int.parse(parts[0]) * 100 +
      (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
  return cents <= 1000000000000 ? cents : null;
}

String moneyInput(int cents) =>
    '${cents ~/ 100},${(cents.abs() % 100).toString().padLeft(2, '0')}';
String moneyText(int cents) {
  final digits = (cents.abs() ~/ 100).toString();
  final chunks = <String>[];
  for (var end = digits.length; end > 0; end -= 3) {
    chunks.insert(0, digits.substring((end - 3).clamp(0, end), end));
  }
  return '${cents < 0 ? '−' : ''}${chunks.join(' ')},${(cents.abs() % 100).toString().padLeft(2, '0')} ₽';
}

String compactMoneyText(int cents) =>
    moneyText(cents).replaceFirst(',00 ₽', ' ₽');

String paymentMethod(String method) => switch (method) {
  'cash' => 'Наличные',
  'transfer' => 'Перевод',
  'card' => 'Карта',
  _ => 'Другое',
};
String financeError(String? reason) => switch (reason) {
  'refund_exceeds_received' =>
    'Сумма возврата превышает полученную оплату по компании.',
  'refund_allocation_required' =>
    'Укажите, с каких участников снять возвращаемую оплату, или сначала измените её распределение.',
  'refund_exceeds_allocation' =>
    'С одного из участников снимается больше, чем ему зачтено. Проверьте распределение возврата.',
  'payment_reversed' =>
    'Платёж уже исправлен на другом устройстве. Откройте актуальную запись.',
  _ => peopleErrorLabel(reason),
};

class PaymentEntry {
  const PaymentEntry(this.data, {this.pending = false, this.conflict = false});
  final JsonMap data;
  final bool pending, conflict;
  String get id => data['id'] as String;
  String get bookingId => data['booking_id'] as String;
  String get direction => data['direction'] as String;
  int get signedKopeks => data['signed_kopeks'] as int;
  int get amount => signedKopeks.abs();
  int get version => data['version'] as int? ?? 1;
  String get method => data['method'] as String? ?? 'other';
  String get notes => data['notes'] as String? ?? '';
  String get reason => data['reason'] as String? ?? '';
  String? get reverses => data['reverses'] as String?;
  String? get correctionOf => data['correction_of'] as String?;
  DateTime get occurredAt => DateTime.parse(data['occurred_at'] as String);
  List<JsonMap> get allocations => (data['allocations'] as List? ?? [])
      .map((a) => Map<String, dynamic>.from(a as Map))
      .toList();
  int get allocated =>
      allocations.fold(0, (sum, a) => sum + (a['amount_kopeks'] as int));
  String get label => direction == 'reversal'
      ? 'Корректировка'
      : direction == 'refund'
      ? 'Возврат'
      : 'Получение';
}

class FinanceView {
  const FinanceView({
    this.payments = const [],
    this.serverPayments = const [],
    this.commands = const [],
    this.priceHistory = const [],
    this.allocationHistory = const [],
    this.ready = false,
  });
  final List<PaymentEntry> payments;
  final List<PaymentEntry> serverPayments;
  int serverNet(String booking) => serverPayments
      .where((p) => p.bookingId == booking)
      .fold(0, (sum, p) => sum + p.signedKopeks);
  final List<PeopleCommand> commands;
  final List<JsonMap> priceHistory, allocationHistory;
  final bool ready;
  bool get provisional => commands.isNotEmpty;
  bool reversed(String id) => payments.any((p) => p.reverses == id);
  List<PaymentEntry> forBooking(String id) =>
      payments.where((p) => p.bookingId == id).toList();
  int net(String? booking) => payments
      .where((p) => booking == null || p.bookingId == booking)
      .fold(0, (sum, p) => sum + p.signedKopeks);
  int received(String? booking) => payments
      .where(
        (p) =>
            (booking == null || p.bookingId == booking) &&
            p.direction == 'income' &&
            !reversed(p.id),
      )
      .fold(0, (sum, p) => sum + p.amount);
  int refunded(String? booking) => payments
      .where(
        (p) =>
            (booking == null || p.bookingId == booking) &&
            p.direction == 'refund' &&
            !reversed(p.id),
      )
      .fold(0, (sum, p) => sum + p.amount);
  int credited(String id, {String? bookingId}) => payments
      .where((p) => bookingId == null || p.bookingId == bookingId)
      .fold(
        0,
        (sum, p) =>
            sum +
            p.allocations
                .where((a) => a['participation_id'] == id)
                .fold(
                  0,
                  (s, a) =>
                      s + p.signedKopeks.sign * (a['amount_kopeks'] as int),
                ),
      );
  int unallocated(String booking) =>
      net(booking) -
      payments
          .where((p) => p.bookingId == booking)
          .fold(0, (sum, p) => sum + p.signedKopeks.sign * p.allocated);

  static FinanceView project(JsonMap? roster, List<PeopleCommand> outbox) {
    final payments = {
      for (final p in roster?['payments'] as List? ?? [])
        p['id'] as String: PaymentEntry(Map<String, dynamic>.from(p as Map)),
    };
    final commands = outbox
        .where((c) => financeKinds.contains(c.kind))
        .toList();
    final confirmed = payments.values.toList();
    for (final c in commands) {
      final x = c.payload;
      final existing = payments[x['id']];
      PaymentEntry entry(JsonMap input) => PaymentEntry(
        {
          ...input,
          'booking_id': x['booking_id'],
          'version': 1,
          'signed_kopeks':
              (input['amount_kopeks'] as int) *
              (input['direction'] == 'refund' ? -1 : 1),
        },
        pending: true,
        conflict: c.error != null,
      );
      if (c.kind == 'add_payment') {
        payments[x['id'] as String] = entry(x);
      }
      if (c.kind == 'allocate_payment' && existing != null) {
        final p = existing;
        payments[p.id] = PaymentEntry(
          {
            ...p.data,
            'version': c.expectedVersion + 1,
            'allocations': x['allocations'],
          },
          pending: true,
          conflict: c.error != null,
        );
      }
      if (c.kind == 'correct_payment' && existing != null) {
        final p = existing;
        payments[p.id] = PaymentEntry(
          {...p.data, 'version': c.expectedVersion + 1},
          pending: true,
          conflict: c.error != null,
        );
        payments[x['reversal_id'] as String] = PaymentEntry(
          {
            ...p.data,
            'id': x['reversal_id'],
            'reverses': p.id,
            'signed_kopeks': -p.signedKopeks,
            'direction': 'reversal',
            'reason': x['reason'],
            'occurred_at': x['occurred_at'],
          },
          pending: true,
          conflict: c.error != null,
        );
        if (x['replacement'] is Map) {
          payments[x['replacement']['id'] as String] = entry(
            Map<String, dynamic>.from(x['replacement'] as Map),
          );
        }
      }
    }
    return FinanceView(
      payments: payments.values.toList(),
      serverPayments: confirmed,
      commands: commands,
      ready: roster?['finance_protocol'] == 1,
      priceHistory: (roster?['price_history'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      allocationHistory: (roster?['allocation_history'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
    );
  }
}
