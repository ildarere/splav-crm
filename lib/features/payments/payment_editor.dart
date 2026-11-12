import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;
import '../../core/prototype.dart';
import '../trips/trip_format.dart';

enum PaymentMode { income, refund, allocate, correct }

class PaymentEditor extends StatefulWidget {
  const PaymentEditor({
    super.key,
    required this.controller,
    required this.booking,
    required this.mode,
    this.source,
    this.initialAllocations,
    this.heading,
  });
  final Stage1Controller controller;
  final Booking booking;
  final PaymentMode mode;
  final PaymentEntry? source;
  final Map<String, int>? initialAllocations;
  final String? heading;
  @override
  State<PaymentEditor> createState() => _PaymentEditorState();
}

class _PaymentEditorState extends State<PaymentEditor> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController(),
      _notes = TextEditingController(),
      _reason = TextEditingController();
  final _allocations = <String, TextEditingController>{};
  late final List<Participation> _people;
  late DateTime _when;
  late String _direction, _method;
  bool _void = false;
  String? _error;
  bool get _allocate => widget.mode == PaymentMode.allocate;
  bool get _correct => widget.mode == PaymentMode.correct;
  @override
  void initState() {
    super.initState();
    final c = widget.controller, s = widget.source;
    final historical = {
      for (final line in s?.allocations ?? <JsonMap>[])
        line['participation_id'],
      if (widget.mode == PaymentMode.refund)
        for (final payment in c.financeView.payments.where(
          (p) => p.bookingId == widget.booking.id,
        ))
          for (final line in payment.allocations) line['participation_id'],
    };
    _people = c.peopleView.participations
        .where(
          (p) => p.bookingId == widget.booking.id || historical.contains(p.id),
        )
        .toList();
    _direction = widget.mode == PaymentMode.refund
        ? 'refund'
        : (_correct || _allocate ? s?.direction ?? 'income' : 'income');
    _method = s?.method ?? 'other';
    _when = s?.occurredAt ?? DateTime.now().toUtc();
    _notes.text = s?.notes ?? '';
    final due = _people.fold(
      0,
      (sum, p) =>
          sum +
          (p.priceKopecks - c.financeView.credited(p.id)).clamp(
            0,
            1000000000000,
          ),
    );
    _amount.text = moneyInput(
      s?.amount ??
          widget.initialAllocations?.values.fold<int>(0, (a, b) => a + b) ??
          (_direction == 'refund' ? c.financeView.net(widget.booking.id) : due),
    );
    for (final p in _people) {
      final amount =
          s?.allocations
                  .where((a) => a['participation_id'] == p.id)
                  .firstOrNull?['amount_kopeks']
              as int? ??
          widget.initialAllocations?[p.id] ??
          0;
      _allocations[p.id] = TextEditingController(
        text: amount == 0 ? '' : moneyInput(amount),
      );
    }
    if (s == null && widget.initialAllocations == null) _distribute();
  }

  @override
  void dispose() {
    for (final field in [_amount, _notes, _reason, ..._allocations.values]) {
      field.dispose();
    }
    super.dispose();
  }

  void _distribute() {
    var remaining = parseKopeks(_amount.text) ?? 0;
    for (final p in _people) {
      if (widget.initialAllocations != null &&
          !widget.initialAllocations!.containsKey(p.id)) {
        _allocations[p.id]!.clear();
        continue;
      }
      var credit = widget.controller.financeView.credited(
        p.id,
        bookingId: _direction == 'refund' ? widget.booking.id : null,
      );
      if (widget.source case final source?) {
        credit -=
            source.signedKopeks.sign *
            (source.allocations
                        .where((a) => a['participation_id'] == p.id)
                        .firstOrNull?['amount_kopeks']
                    as int? ??
                0);
      }
      final available = _direction == 'refund'
          ? credit
          : (p.priceKopecks - credit).clamp(0, 1000000000000);
      final part = remaining.clamp(0, available.clamp(0, 1000000000000));
      remaining -= part;
      _allocations[p.id]!.text = part == 0 ? '' : moneyInput(part);
    }
  }

  Future<void> _date() async {
    final zone = tz.getLocation(widget.controller.selectedTrip!.timeZone);
    final local = tz.TZDateTime.from(_when, zone);
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime(local.year, local.month, local.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: local.hour, minute: local.minute),
    );
    if (time != null && mounted) {
      setState(
        () => _when = tz.TZDateTime(
          zone,
          date.year,
          date.month,
          date.day,
          time.hour,
          time.minute,
        ).toUtc(),
      );
    }
  }

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final amount = parseKopeks(_amount.text) ?? 0;
    final allocations = [
      for (final entry in _allocations.entries)
        if ((parseKopeks(entry.value.text) ?? 0) > 0)
          <String, dynamic>{
            'participation_id': entry.key,
            'amount_kopeks': parseKopeks(entry.value.text),
          },
    ];
    if (!_void &&
        allocations.fold<int>(
              0,
              (sum, a) => sum + (a['amount_kopeks'] as int),
            ) >
            amount) {
      setState(() => _error = 'Распределено больше суммы платежа.');
      return;
    }
    final payment = <String, dynamic>{
      'amount_kopeks': amount,
      'direction': _direction,
      'occurred_at': _when.toUtc().toIso8601String(),
      'method': _method,
      'notes': _notes.text.trim(),
      'allocations': allocations,
    };
    Navigator.pop(context, <String, dynamic>{
      'kind': _allocate
          ? 'allocate_payment'
          : _correct
          ? 'correct_payment'
          : 'add_payment',
      'payload': _allocate
          ? {
              'id': widget.source!.id,
              'booking_id': widget.booking.id,
              'allocations': allocations,
              'reason': _reason.text.trim(),
            }
          : _correct
          ? {
              'id': widget.source!.id,
              'booking_id': widget.booking.id,
              'reason': _reason.text.trim(),
              'replacement': _void ? null : payment,
            }
          : {...payment, 'booking_id': widget.booking.id},
      'version': widget.source?.version ?? 0,
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = _allocations.values.fold<int>(
      0,
      (sum, c) => sum + (parseKopeks(c.text) ?? 0),
    );
    return AlertDialog(
      title: Text(
        widget.heading ??
            (_allocate
                ? 'Распределить оплату'
                : _correct
                ? 'Исправить платёж'
                : _direction == 'refund'
                ? 'Возврат по компании'
                : 'Получение оплаты'),
      ),
      scrollable: true,
      content: SizedBox(
        width: 600,
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              Text('Компания · ${widget.booking.contactName}'),
              if (widget.initialAllocations != null)
                const Text(
                  'Уже внесённые суммы учтены. Проверьте сумму и распределение перед сохранением.',
                ),
              if (_correct) ...[
                const Text(
                  'Исходная запись сохранится. Корректировка отменит её влияние на итоги и при необходимости создаст верный вариант.',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _void,
                  onChanged: (v) => setState(() => _void = v!),
                  title: const Text('Аннулировать ошибочную запись без замены'),
                ),
              ],
              if (!_void) ...[
                TextFormField(
                  controller: _amount,
                  readOnly: _allocate,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    counterText: '',
                    labelText: 'Сумма, ₽',
                  ),
                  onChanged: (_) => setState(() {
                    _error = null;
                    if (!_allocate && !_correct) _distribute();
                  }),
                  validator: (v) => (parseKopeks(v ?? '') ?? 0) <= 0
                      ? 'Введите положительную сумму, не больше двух знаков после запятой'
                      : null,
                ),
                if (!_allocate) ...[
                  OutlinedButton.icon(
                    onPressed: _date,
                    icon: const Icon(Icons.event_outlined),
                    label: Text(
                      tripDate(_when, widget.controller.selectedTrip!.timeZone),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  TextFormField(
                    controller: _notes,
                    maxLength: 2000,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      counterText: '',
                      labelText: 'Комментарий',
                    ),
                  ),
                ],
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  maintainState: true,
                  title: Text(
                    _direction == 'refund'
                        ? 'С кого снять возвращаемую оплату'
                        : 'Кому зачесть оплату',
                  ),
                  subtitle: Text('Распределено ${moneyText(total)}'),
                  children: [
                    OutlinedButton(
                      onPressed: () => setState(_distribute),
                      child: Text(
                        _direction == 'refund'
                            ? 'Предложить распределение возврата'
                            : 'Распределить по задолженности',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    for (final p in _people)
                      TextFormField(
                        controller: _allocations[p.id],
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          counterText: '',
                          labelText:
                              widget.controller.peopleView
                                  .person(p.personId)
                                  ?.name ??
                              'Участник',
                          helperText:
                              'Стоимость ${moneyText(p.priceKopecks)} · зачтено ${moneyText(widget.controller.financeView.credited(p.id))}',
                          helperMaxLines: 3,
                        ),
                        onChanged: (_) => setState(() => _error = null),
                        validator: (v) =>
                            (v ?? '').trim().isNotEmpty &&
                                parseKopeks(v!) == null
                            ? 'Введите сумму в рублях с точностью до копейки'
                            : null,
                      ),
                    Text(
                      'Распределено ${moneyText(total)} · не распределено ${moneyText((parseKopeks(_amount.text) ?? 0) - total)}',
                    ),
                  ],
                ),
              ],
              if (_allocate || _correct)
                TextFormField(
                  controller: _reason,
                  maxLength: 2000,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    counterText: '',
                    labelText: 'Причина изменения',
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'Укажите причину для истории'
                      : null,
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(
            _allocate
                ? 'Сохранить распределение'
                : _correct
                ? 'Сохранить корректировку'
                : 'Сохранить платёж',
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

class PriceEditor extends StatefulWidget {
  const PriceEditor({super.key, required this.people, required this.view});
  final List<Participation> people;
  final PeopleView view;
  @override
  State<PriceEditor> createState() => _PriceEditorState();
}

class _PriceEditorState extends State<PriceEditor> {
  final _form = GlobalKey<FormState>(), _reason = TextEditingController();
  late final _prices = {
    for (final p in widget.people)
      p.id: TextEditingController(text: moneyInput(p.priceKopecks)),
  };
  @override
  void dispose() {
    _reason.dispose();
    for (final c in _prices.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Согласованная стоимость'),
    scrollable: true,
    content: SizedBox(
      width: 540,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 16,
          children: [
            const Text(
              'Стоимость уже записанных людей меняется этим действием. Базовая цена сплава применяется к новым записям.',
            ),
            for (final p in widget.people)
              TextFormField(
                controller: _prices[p.id],
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  counterText: '',
                  labelText: widget.view.person(p.personId)?.name ?? 'Участник',
                  suffixText: '₽',
                ),
                validator: (v) => parseKopeks(v ?? '') == null
                    ? 'Укажите неотрицательную стоимость до копейки'
                    : null,
              ),
            TextFormField(
              controller: _reason,
              maxLength: 2000,
              decoration: const InputDecoration(
                counterText: '',
                labelText: 'Причина',
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Укажите причину' : null,
            ),
          ],
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
          if (_form.currentState?.validate() ?? false) {
            Navigator.pop(context, <String, dynamic>{
              'reason': _reason.text.trim(),
              'lines': [
                for (final p in widget.people)
                  {
                    'id': p.id,
                    'version': p.version,
                    'amount_kopeks': parseKopeks(_prices[p.id]!.text),
                  },
              ],
            });
          }
        },
        child: const Text('Сохранить стоимость'),
      ),
    ],
  );
}
