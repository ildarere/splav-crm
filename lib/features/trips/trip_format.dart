import 'package:timezone/timezone.dart' as tz;

String tripDate(DateTime value, String zone, {bool includeTime = true}) {
  final date = tz.TZDateTime.from(value, tz.getLocation(zone));
  String two(int number) => number.toString().padLeft(2, '0');
  final day = '${two(date.day)}.${two(date.month)}.${date.year}';
  return includeTime ? '$day ${two(date.hour)}:${two(date.minute)}' : day;
}

DateTime tripLocalDate(DateTime value, String zone) =>
    tz.TZDateTime.from(value, tz.getLocation(zone));

String tripStatusLabel(String status) => switch (status) {
  'draft' => 'Черновик',
  'open' => 'Запись открыта',
  'closed' => 'Запись закрыта',
  'in_progress' => 'В поездке',
  'completed' => 'Завершён',
  'cancelled' => 'Отменён',
  _ => status,
};

String conflictReasonLabel(String? reason) => switch (reason) {
  'version_conflict' => 'Выезд изменён на другом устройстве.',
  'capacity_below_confirmed' => 'Лимит меньше числа подтверждённых участников.',
  'invalid_transition' => 'Этот переход статуса сейчас недоступен.',
  'trip_finalized' => 'Завершённый или отменённый выезд закрыт для изменений.',
  'trip_exists' => 'Выезд с таким идентификатором уже существует.',
  _ => 'Изменение требует проверки.',
};
