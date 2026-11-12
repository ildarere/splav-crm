import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';
import '../../core/prototype.dart';
import '../trips/trip_format.dart';
import 'operations_widgets.dart';

Future<void> editReservation(
  BuildContext context,
  Stage1Controller c,
  String kind, [
  JsonMap? booking,
]) async {
  final result = await operationDialog<JsonMap>(
    context,
    c,
    ReservationEditor(controller: c, kind: kind, booking: booking),
  );
  if (result != null && context.mounted) {
    await performOperation(
      context,
      c,
      'ops_reservation',
      result,
      version: booking?['version'] as int? ?? 0,
    );
  }
}

Future<void> cancelReservation(
  BuildContext context,
  Stage1Controller c,
  JsonMap booking,
) async {
  final reason = await operationReason(
    context,
    c,
    'Отменить бронь / рейс',
    initial: 'План отменён организатором',
  );
  if (reason != null && context.mounted) {
    await performOperation(context, c, 'ops_reservation', {
      ...booking,
      'active': false,
      'reason': reason,
    }, version: booking['version'] as int);
  }
}

class ReservationEditor extends StatefulWidget {
  const ReservationEditor({
    super.key,
    required this.controller,
    required this.kind,
    this.booking,
  });
  final Stage1Controller controller;
  final String kind;
  final JsonMap? booking;
  @override
  State<ReservationEditor> createState() => _ReservationEditorState();
}

class _ReservationEditorState extends State<ReservationEditor> {
  final _form = GlobalKey<FormState>();
  late DateTime _start, _end;
  String? _resource, _responsible, _role, _error;
  late String _direction;
  late int _capacity;
  late bool _active;
  late final _prep = TextEditingController(
    text: '${widget.booking?['prep_minutes'] ?? 0}',
  );
  late final _tail = TextEditingController(
    text: '${widget.booking?['return_minutes'] ?? 0}',
  );
  late final _notes = TextEditingController(
    text: widget.booking?['notes'] as String? ?? '',
  );
  late final List<JsonMap> _points;
  @override
  void initState() {
    super.initState();
    final b = widget.booking, t = widget.controller.selectedTrip!;
    _start = b == null
        ? (widget.kind == 'ride' ? t.meetingAt : t.startsAt)
        : DateTime.parse(b['starts_at'] as String);
    _end = b == null
        ? (widget.kind == 'ride' ? t.startsAt : t.endsAt)
        : DateTime.parse(b['ends_at'] as String);
    if (widget.kind == 'boat') {
      _start = t.startsAt;
      _end = t.endsAt;
    }
    if (!_end.isAfter(_start)) _end = _start.add(const Duration(hours: 1));
    _resource = b?['resource_id'] as String?;
    _responsible = b?['responsible_id'] as String?;
    _role = b?['role'] as String?;
    _direction = b?['direction'] as String? ?? 'outbound';
    _capacity = b?['capacity'] as int? ?? 1;
    _active = b?['active'] as bool? ?? true;
    _points = operationRows(b?['points']);
    if (_points.isEmpty && widget.kind == 'ride') {
      _points.add({'id': 'free-seating', 'name': 'Свободная посадка'});
    }
  }

  @override
  void dispose() {
    for (final c in [_prep, _tail, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  List<JsonMap> get _resources => widget.controller.operationsView.resources
      .where(
        (r) =>
            r['kind'] ==
            (widget.kind == 'ride'
                ? 'vehicle'
                : widget.kind == 'duty'
                ? 'employee'
                : 'boat'),
      )
      .toList();
  List<int> capacities(JsonMap? r) => widget.kind == 'duty'
      ? [1]
      : r?['planned'] == true
      ? [r?['capacity'] as int? ?? 2]
      : switch (r?['model']) {
          'big' => [3, 4],
          'rf' => [2, 3],
          'maigun' => [2],
          'own_bus' => [30],
          'secondary_bus' => [16, 17, 19, 20],
          'taxi' => [4],
          _ => [
            for (
              var i = widget.kind == 'boat' ? 2 : 1;
              i <= (r?['capacity'] as int? ?? 2);
              i++
            )
              i,
          ],
        };
  Future<void> _pick(bool start) async {
    final zone = tz.getLocation(widget.controller.selectedTrip!.timeZone);
    final local = tz.TZDateTime.from(start ? _start : _end, zone);
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
      setState(() {
        final value = tz.TZDateTime(
          zone,
          date.year,
          date.month,
          date.day,
          time.hour,
          time.minute,
        ).toUtc();
        if (start) {
          _start = value;
        } else {
          _end = value;
        }
        _error = null;
      });
    }
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    if (widget.kind == 'boat') {
      _start = widget.controller.selectedTrip!.startsAt;
      _end = widget.controller.selectedTrip!.endsAt;
    }
    if (!_end.isAfter(_start)) {
      setState(() => _error = 'Окончание должно быть позже начала.');
      return;
    }
    final prep = widget.kind == 'boat' ? 0 : int.parse(_prep.text),
        tail = widget.kind == 'boat' ? 0 : int.parse(_tail.text);
    if (_active &&
        widget.controller.operationsView.resourceBusy(
          _resource!,
          _start.subtract(Duration(minutes: prep)),
          _end.add(Duration(minutes: tail)),
          except: widget.booking?['id'] as String?,
        )) {
      setState(
        () => _error =
            'По сохранённым данным ресурс уже занят в это время, включая подготовку и возврат.',
      );
      return;
    }
    Navigator.pop(context, <String, dynamic>{
      'id': widget.booking?['id'] ?? const Uuid().v4(),
      'kind': widget.kind,
      'resource_id': _resource,
      'starts_at': _start.toUtc().toIso8601String(),
      'ends_at': _end.toUtc().toIso8601String(),
      'prep_minutes': prep,
      'return_minutes': tail,
      'capacity': _capacity,
      'active': _active,
      'direction': _direction,
      'role': _role,
      'responsible_id': _responsible,
      'points': _points,
      'notes': _notes.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller,
        o = c.operationsView,
        resource = o.resource(_resource);
    final options = capacities(resource);
    if (!options.contains(_capacity)) _capacity = options.first;
    final roles = (resource?['roles'] as List? ?? []).cast<String>();
    if (_role != null && !roles.contains(_role)) _role = null;
    return AlertDialog(
      title: Text(
        widget.kind == 'boat'
            ? 'Бронь байдарки'
            : widget.kind == 'ride'
            ? 'Рейс'
            : 'Работа на выезде',
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
              if (widget.kind == 'boat')
                const Text('Время брони совпадает со временем сплава.'),
              if (widget.booking == null && widget.kind == 'duty')
                const Text(
                  'Время предложено по выезду. Уточните фактический план, подготовку и возврат.',
                ),
              DropdownButtonFormField<String>(
                initialValue: _resource,
                isExpanded: true,
                decoration: InputDecoration(
                  counterText: '',
                  labelText: widget.kind == 'boat'
                      ? 'Байдарка'
                      : widget.kind == 'ride'
                      ? 'Транспорт'
                      : 'Работник',
                ),
                items: [
                  for (final r in _resources)
                    DropdownMenuItem(
                      value: r['id'] as String,
                      enabled: r['available'] == true || r['id'] == _resource,
                      child: Text(
                        '${r['name']} · ${r['code']}${r['available'] == true ? '' : ' · недоступен'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                validator: (v) => v == null ? 'Выберите ресурс' : null,
                onChanged: (v) => setState(() {
                  _resource = v;
                  _capacity = capacities(o.resource(v)).first;
                  _role = null;
                  _error = null;
                }),
              ),
              if (widget.kind != 'duty')
                DropdownButtonFormField<int>(
                  key: ValueKey(_resource),
                  initialValue: _capacity,
                  decoration: const InputDecoration(
                    counterText: '',
                    labelText: 'Мест в этом назначении',
                  ),
                  items: [
                    for (final v in options)
                      DropdownMenuItem(value: v, child: Text('$v')),
                  ],
                  onChanged: (v) => setState(() => _capacity = v!),
                ),
              if (widget.kind == 'boat' && resource != null)
                Text(
                  resource['model'] == 'big'
                      ? 'На 4 места можно назначать только детей ростом ниже 130 см. Заполните рост и возраст.'
                      : resource['model'] == 'rf'
                      ? '2 обычных места; дополнительное — при росте до 155 см и весе до 50 кг.'
                      : 'Каждый человек занимает одно место.',
                ),
              if (widget.kind == 'duty')
                DropdownButtonFormField<String>(
                  key: ValueKey(_resource),
                  initialValue: _role,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    counterText: '',
                    labelText: 'Работа / специализация',
                  ),
                  items: [
                    for (final r in roles)
                      DropdownMenuItem(
                        value: r,
                        child: Text(workerRoles[r] ?? r, maxLines: 2),
                      ),
                  ],
                  validator: (v) => v == null ? 'Выберите работу' : null,
                  onChanged: (v) => _role = v,
                ),
              if (widget.kind != 'boat') ...[
                OutlinedButton.icon(
                  onPressed: () => _pick(true),
                  icon: const Icon(Icons.event_outlined),
                  label: Text(
                    'Начало · ${tripDate(_start, c.selectedTrip!.timeZone)}',
                    textAlign: TextAlign.center,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _pick(false),
                  icon: const Icon(Icons.event_outlined),
                  label: Text(
                    'Окончание · ${tripDate(_end, c.selectedTrip!.timeZone)}',
                    textAlign: TextAlign.center,
                  ),
                ),
                if (widget.kind == 'duty')
                  for (final e in [
                    (_prep, 'Подготовка до начала, мин'),
                    (_tail, 'Возврат / освобождение после, мин'),
                  ])
                    TextFormField(
                      controller: e.$1,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        counterText: '',
                        labelText: e.$2,
                      ),
                      validator: (v) {
                        final n = int.tryParse(v ?? '');
                        return n == null || n < 0 || n > 10080
                            ? 'От 0 до 10080 минут'
                            : null;
                      },
                    ),
              ],
              if (widget.kind == 'ride') ...[
                DropdownButtonFormField<String>(
                  initialValue: _responsible,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    counterText: '',
                    labelText: 'Ответственный (организатор, если не указан)',
                  ),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('Организатор'),
                    ),
                    for (final r in o.resources.where(
                      (r) => r['kind'] == 'employee',
                    ))
                      DropdownMenuItem(
                        value: r['id'] as String,
                        child: Text(
                          r['name'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => _responsible = v,
                ),
              ],
              if (widget.kind != 'boat')
                TextFormField(
                  controller: _notes,
                  decoration: const InputDecoration(
                    counterText: '',
                    labelText: 'Примечание',
                  ),
                  maxLength: 2000,
                  maxLines: 3,
                ),
              if (widget.booking != null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Бронь действует'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v!),
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
            widget.kind == 'ride' ? 'Сохранить рейс' : 'Сохранить бронь',
          ),
        ),
      ],
    );
  }
}
