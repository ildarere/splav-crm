import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/stage1_models.dart';
import 'trip_format.dart';

class TripEditor extends StatefulWidget {
  const TripEditor({
    super.key,
    required this.teams,
    required this.routes,
    this.trip,
  });

  final List<TripTeam> teams;
  final List<TripRoute> routes;
  final Trip? trip;

  @override
  State<TripEditor> createState() => _TripEditorState();
}

class _TripEditorState extends State<TripEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title;
  late String _zone;
  late final TextEditingController _meetingPoint;
  late String _responsible;
  late final TextEditingController _capacity;
  late final TextEditingController _price;
  late final TextEditingController _notes;
  late String _teamId;
  String? _routeId;
  late String _status;
  late DateTime _start;
  late DateTime _end;
  late DateTime _meeting;
  String? _scheduleError;
  bool _series = false;
  DateTimeRange? _range;
  final _weekdays = <int>{};

  List<DateTime> get _dates {
    final range = _range;
    if (range == null || _weekdays.isEmpty) return [];
    return [
      for (
        var day = range.start;
        !day.isAfter(range.end);
        day = DateTime(day.year, day.month, day.day + 1)
      )
        if (_weekdays.contains(day.weekday)) day,
    ];
  }

  Future<void> _pickRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: _range,
    );
    if (range != null && mounted) {
      setState(() {
        _range = range;
        _scheduleError = null;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    final trip = widget.trip;
    _teamId = trip?.teamId ?? widget.teams.firstWhere((t) => t.canCreate).id;
    final teamRoutes = widget.routes.where((r) => r.teamId == _teamId);
    _routeId = trip == null
        ? teamRoutes.firstOrNull?.id
        : teamRoutes.any((route) => route.id == trip.routeId)
        ? trip.routeId
        : null;
    _title = TextEditingController(text: trip?.title ?? '');
    _zone = trip?.timeZone ?? 'Europe/Saratov';
    _meetingPoint = TextEditingController(text: trip?.meetingPoint ?? '');
    _responsible = trip?.responsibleNames ?? '';
    _capacity = TextEditingController(text: '${trip?.capacity ?? 50}');
    final kopecks = trip?.basePriceKopecks ?? 700000;
    _price = TextEditingController(
      text: '${kopecks ~/ 100},${(kopecks % 100).toString().padLeft(2, '0')}',
    );
    _notes = TextEditingController(text: trip?.notes ?? '');
    _status = trip?.status ?? 'draft';
    final now = tripLocalDate(DateTime.now(), _zone);
    final tomorrow = DateTime(now.year, now.month, now.day + 1, 8);
    _start = trip == null ? tomorrow : _wallClock(trip.startsAt, trip.timeZone);
    _end = trip == null
        ? tomorrow.add(const Duration(days: 1, hours: 11))
        : _wallClock(trip.endsAt, trip.timeZone);
    _meeting = trip == null
        ? tomorrow.subtract(const Duration(hours: 1))
        : _wallClock(trip.meetingAt, trip.timeZone);
  }

  DateTime _wallClock(DateTime instant, String zone) {
    final local = tripLocalDate(instant, zone);
    return DateTime(
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
    );
  }

  @override
  void dispose() {
    for (final field in [_title, _meetingPoint, _capacity, _price, _notes]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDateTime(
    DateTime value,
    ValueChanged<DateTime> onChanged,
  ) async {
    final day = await showDatePicker(
      context: context,
      initialDate: value,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Дата выезда',
      cancelText: 'Отмена',
      confirmText: 'Выбрать',
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(value),
      helpText: 'Время в часовом поясе выезда',
      cancelText: 'Отмена',
      confirmText: 'Выбрать',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (time == null || !mounted) return;
    setState(
      () => onChanged(
        DateTime(day.year, day.month, day.day, time.hour, time.minute),
      ),
    );
  }

  int? _priceKopecks(String? raw) {
    final match = RegExp(
      r'^(\d{1,8})(?:[.,](\d{1,2}))?$',
    ).firstMatch((raw ?? '').trim());
    if (match == null) return null;
    final kopecks =
        int.parse(match[1]!) * 100 +
        int.parse((match[2] ?? '').padRight(2, '0'));
    return kopecks <= 1000000000 ? kopecks : null;
  }

  void _submit() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final zone = tz.getLocation(_zone.trim());
    DateTime instant(DateTime wall) => tz.TZDateTime(
      zone,
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
    ).toUtc();
    final startsAt = instant(_start);
    final endsAt = instant(_end);
    final meetingAt = instant(_meeting);
    if (!endsAt.isAfter(startsAt) || meetingAt.isAfter(startsAt)) {
      setState(
        () => _scheduleError =
            'Окончание должно быть позже начала, а сбор — до начала или одновременно с ним.',
      );
      return;
    }
    final dates = _series ? _dates : [_start];
    if (dates.isEmpty) {
      setState(
        () =>
            _scheduleError = 'Выберите диапазон и дни недели с датами выездов.',
      );
      return;
    }
    final templateDay = DateTime.utc(_start.year, _start.month, _start.day);
    DateTime shift(DateTime value, DateTime date) {
      final offset = DateTime.utc(
        value.year,
        value.month,
        value.day,
      ).difference(templateDay).inDays;
      return instant(
        DateTime(
          date.year,
          date.month,
          date.day + offset,
          value.hour,
          value.minute,
        ),
      );
    }

    TripDraft draft(DateTime date) => TripDraft(
      teamId: _teamId,
      title: _title.text.trim(),
      routeId: _routeId!,
      startsAt: shift(_start, date),
      endsAt: shift(_end, date),
      timeZone: _zone.trim(),
      meetingPoint: _meetingPoint.text.trim(),
      meetingAt: shift(_meeting, date),
      responsibleNames: _responsible.trim(),
      capacity: int.parse(_capacity.text),
      basePriceKopecks: _priceKopecks(_price.text)!,
      notes: _notes.text.trim(),
      status: _status,
    );
    Navigator.pop(context, _series ? dates.map(draft).toList() : draft(_start));
  }

  @override
  Widget build(BuildContext context) {
    final dates = _series ? _dates : const <DateTime>[];
    final routes = widget.routes.where((r) => r.teamId == _teamId).toList();
    final teams = widget.teams
        .where((t) => t.canCreate || t.id == widget.trip?.teamId)
        .toList();
    return AlertDialog(
      title: Text(widget.trip == null ? 'Новый выезд' : 'Изменить выезд'),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              if (teams.length > 1)
                DropdownButtonFormField<String>(
                  initialValue: _teamId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    counterText: '',
                    labelText: 'Команда',
                  ),
                  items: teams
                      .map(
                        (t) =>
                            DropdownMenuItem(value: t.id, child: Text(t.name)),
                      )
                      .toList(),
                  onChanged: widget.trip != null
                      ? null
                      : (value) => setState(() {
                          _teamId = value!;
                          _routeId = widget.routes
                              .where((r) => r.teamId == value)
                              .firstOrNull
                              ?.id;
                        }),
                ),
              TextFormField(
                controller: _title,
                autofocus: true,
                maxLength: 150,
                decoration: const InputDecoration(
                  counterText: '',
                  labelText: 'Название *',
                ),
                validator: (value) =>
                    (value ?? '').trim().isEmpty ? 'Введите название' : null,
              ),
              DropdownButtonFormField<String>(
                key: ValueKey('route-$_teamId'),
                initialValue: _routeId,
                isExpanded: true,
                decoration: const InputDecoration(
                  counterText: '',
                  labelText: 'Маршрут *',
                ),
                items: routes
                    .map(
                      (r) => DropdownMenuItem(value: r.id, child: Text(r.name)),
                    )
                    .toList(),
                onChanged: (value) => _routeId = value,
                validator: (value) => value == null
                    ? 'Сначала добавьте маршрут в справочник'
                    : null,
              ),
              if (widget.trip != null)
                TextFormField(
                  initialValue: _zone,
                  decoration: const InputDecoration(
                    labelText: 'Часовой пояс',
                    helperText: 'Например Europe/Saratov или Europe/Moscow',
                  ),
                  onChanged: (value) => _zone = value,
                  validator: (value) {
                    try {
                      tz.getLocation((value ?? '').trim());
                      return null;
                    } catch (_) {
                      return 'Укажите существующий часовой пояс IANA';
                    }
                  },
                ),
              _DateTimeField(
                label: 'Начало',
                value: _start,
                onTap: () => _pickDateTime(_start, (v) => _start = v),
              ),
              _DateTimeField(
                label: 'Окончание',
                value: _end,
                onTap: () => _pickDateTime(_end, (v) => _end = v),
              ),
              _DateTimeField(
                label: 'Сбор',
                value: _meeting,
                onTap: () => _pickDateTime(_meeting, (v) => _meeting = v),
              ),
              if (widget.trip == null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Серия выездов'),
                  value: _series,
                  onChanged: (value) => setState(() {
                    _series = value;
                    _scheduleError = null;
                  }),
                ),
              if (_series) ...[
                OutlinedButton(
                  onPressed: _pickRange,
                  child: Text(
                    _range == null
                        ? 'Выбрать диапазон дат'
                        : '${MaterialLocalizations.of(context).formatCompactDate(_range!.start)} — ${MaterialLocalizations.of(context).formatCompactDate(_range!.end)}',
                  ),
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final (index, label) in [
                      'Пн',
                      'Вт',
                      'Ср',
                      'Чт',
                      'Пт',
                      'Сб',
                      'Вс',
                    ].indexed)
                      FilterChip(
                        label: Text(label),
                        selected: _weekdays.contains(index + 1),
                        onSelected: (selected) => setState(() {
                          if (selected) {
                            _weekdays.add(index + 1);
                          } else {
                            _weekdays.remove(index + 1);
                          }
                          _scheduleError = null;
                        }),
                      ),
                  ],
                ),
                Text('Выездов: ${dates.length}'),
                if (dates.isNotEmpty)
                  SizedBox(
                    height: 100,
                    child: ListView.builder(
                      itemCount: dates.length,
                      itemBuilder: (context, index) => Text(
                        MaterialLocalizations.of(
                          context,
                        ).formatCompactDate(dates[index]),
                      ),
                    ),
                  ),
              ],
              if (_scheduleError != null)
                Text(
                  _scheduleError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              TextFormField(
                controller: _meetingPoint,
                maxLength: 300,
                decoration: const InputDecoration(
                  counterText: '',
                  labelText: 'Место сбора',
                ),
              ),
              if (widget.trip != null)
                TextFormField(
                  initialValue: _responsible,
                  maxLength: 300,
                  decoration: const InputDecoration(
                    counterText: '',
                    labelText: 'Ответственные',
                  ),
                  onChanged: (value) => _responsible = value,
                ),
              TextFormField(
                controller: _capacity,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  counterText: '',
                  labelText: 'Лимит клиентов *',
                  helperText:
                      'Ориентир для планирования. Запись сверх лимита разрешена.',
                  helperMaxLines: 2,
                ),
                validator: (value) {
                  final number = int.tryParse(value ?? '');
                  return number == null || number < 1 || number > 100000
                      ? 'Введите число от 1 до 100000'
                      : null;
                },
              ),
              TextFormField(
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  counterText: '',
                  labelText: 'Базовая стоимость, ₽ *',
                ),
                validator: (value) => _priceKopecks(value) == null
                    ? 'Введите сумму с точностью до копейки'
                    : null,
              ),
              DropdownButtonFormField<String>(
                initialValue: _status,
                isExpanded: true,
                decoration: const InputDecoration(
                  counterText: '',
                  labelText: 'Статус',
                ),
                items:
                    [
                          'draft',
                          'open',
                          'closed',
                          'in_progress',
                          'completed',
                          'cancelled',
                        ]
                        .map(
                          (s) => DropdownMenuItem(
                            value: s,
                            child: Text(tripStatusLabel(s)),
                          ),
                        )
                        .toList(),
                onChanged: (value) => _status = value!,
              ),
              TextFormField(
                controller: _notes,
                maxLength: 2000,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  counterText: '',
                  labelText: 'Примечание',
                ),
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
        FilledButton(onPressed: _submit, child: const Text('Сохранить')),
      ],
    );
  }
}

class _DateTimeField extends StatelessWidget {
  const _DateTimeField({
    required this.label,
    required this.value,
    required this.onTap,
  });
  final String label;
  final DateTime value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    String two(int n) => n.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.calendar_month_outlined),
        label: Text(
          '$label · ${two(value.day)}.${two(value.month)}.${value.year} ${two(value.hour)}:${two(value.minute)}',
        ),
      ),
    );
  }
}
