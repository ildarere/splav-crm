typedef JsonMap = Map<String, dynamic>;

String normalizedPhone(String value) {
  var digits = value.replaceAll(RegExp(r'\D'), '');
  if (digits.length == 11 && digits.startsWith('8')) {
    digits = '7${digits.substring(1)}';
  }
  return digits;
}

String participationLabel(String status) => switch (status) {
  'application' => 'Новый',
  'confirmed' => 'Подтверждено',
  'waiting' => 'Лист ожидания',
  'cancelled' => 'Отменено',
  _ => status,
};

String peopleErrorLabel(String? reason) => switch (reason) {
  'work_schedule_overlap' => 'Время пересекается с другой сменой работника.',
  'capacity_reached' =>
    'Прежний отказ по лимиту. Запись сверх лимита теперь разрешена — повторите изменение.',
  'version_conflict' =>
    'Данные изменены на другом устройстве. Сравните варианты перед сохранением.',
  'already_registered' =>
    'Человек уже есть в этом выезде. Откройте существующую запись, чтобы восстановить участие.',
  'invalid_restore' => 'Отдельно можно вернуть клиента из резерва или отмены.',
  'participant_unavailable' =>
    'Участие уже отменено или недоступно для переноса.',
  'duplicate_participation' =>
    'Обе карточки участвуют в одном выезде. Сначала разберите эти записи.',
  'trip_not_open' => 'Запись на этот выезд закрыта.',
  'trip_finalized' =>
    'Выезд завершён или отменён. Его состав доступен для просмотра.',
  'person_archived' =>
    'Для новой записи сначала восстановите карточку человека из архива.',
  'person_merged' =>
    'Карточка объединена с другой. Выберите актуальную карточку.',
  'access_denied' => 'Доступ к этим данным отозван.',
  'dependency_failed' => 'Сначала разрешите конфликт предыдущего изменения.',
  'invalid_fields' => 'Проверьте заполненные поля и допустимые значения.',
  'invalid_merge' => 'Выберите две разные действующие карточки одной команды.',
  'empty_booking' => 'Добавьте в новую компанию хотя бы одного участника.',
  _ => 'Изменение требует проверки.',
};

class PersonCard {
  const PersonCard(this.data, {this.pending = false, this.conflict = false});
  final JsonMap data;
  final bool pending;
  final bool conflict;
  String get id => data['id'] as String;
  String get teamId => data['team_id'] as String;
  String get name => data['name'] as String;
  String get phone => data['phone'] as String? ?? '';
  String? get birthDate => data['birth_date'] as String?;
  String get notes => data['notes'] as String? ?? '';
  List<JsonMap> get workAssignments => (data['work_assignments'] as List? ?? [])
      .map((s) => Map<String, dynamic>.from(s as Map))
      .toList();
  bool get isWorker => data['is_worker'] == true;
  String? get workResourceId => data['work_resource_id'] as String?;
  List<String> get workRoles =>
      (data['work_roles'] as List? ?? []).cast<String>();
  List<JsonMap> get workSchedule => (data['work_schedule'] as List? ?? [])
      .map((s) => Map<String, dynamic>.from(s as Map))
      .toList();
  bool get archived => data['archived'] == true;
  String? get mergedInto => data['merged_into'] as String?;
  int get version => data['version'] as int? ?? 0;
  JsonMap get payload => {...data}
    ..remove('version')
    ..remove('merged_into')
    ..remove('team_id')
    ..remove('work_assignments')
    ..remove('work_resource_id');
}

class Booking {
  const Booking(this.data, {this.pending = false, this.conflict = false});
  final JsonMap data;
  final bool pending;
  final bool conflict;
  String get id => data['id'] as String;
  String get tripId => data['trip_id'] as String;
  String get contactName => data['contact_name'] as String? ?? '';
  String get phone => data['phone'] as String? ?? '';
  String? get contactPersonId => data['contact_person_id'] as String?;
  String get notes => data['notes'] as String? ?? '';
  int get version => data['version'] as int? ?? 0;
}

class Participation {
  const Participation(
    this.data, {
    this.pending = false,
    this.conflict = false,
    this.requestedStatus,
  });
  final JsonMap data;
  final bool pending;
  final bool conflict;
  final String? requestedStatus;
  String get id => data['id'] as String;
  String get personId => data['person_id'] as String;
  String get bookingId => data['booking_id'] as String;
  String get tripId => data['trip_id'] as String;
  String get role => data['role'] as String? ?? 'client';
  String get status => data['status'] as String? ?? 'application';
  int get version => data['version'] as int? ?? 0;
  int get priceKopecks => data['agreed_price_kopeks'] as int? ?? 0;
  JsonMap get parameters =>
      Map<String, dynamic>.from(data['parameters'] as Map? ?? {});
  DateTime? get waitingAt =>
      DateTime.tryParse(data['waiting_at'] as String? ?? '');
}

class PeopleCommand {
  const PeopleCommand({
    required this.id,
    required this.teamId,
    required this.kind,
    required this.payload,
    this.tripId,
    this.originTripId,
    this.expectedVersion = 0,
    this.dependencies = const [],
    this.ackRevision,
    this.error,
  });
  final String id;
  final String teamId;
  final String? tripId;
  // A global card created as part of a trip draft shares its access lifecycle.
  final String? originTripId;
  final String kind;
  final JsonMap payload;
  final int expectedVersion;
  final List<String> dependencies;
  final int? ackRevision;
  final String? error;
  Set<String> get personIds => {
    if (kind == 'save_person' || kind == 'merge_people')
      payload['id'] as String,
    if (kind == 'merge_people') payload['target_id'] as String,
  };
  Set<String> get participationIds => {
    if (['ops_crew', 'ops_travel', 'ops_presence'].contains(kind) &&
        (payload['subject_kind'] ?? 'participant') == 'participant')
      payload['subject_id'] as String,
    if (kind == 'ops_crew' && payload['swap_id'] is String)
      payload['swap_id'] as String,
    if (kind == 'set_status') ...(payload['ids'] as List).cast<String>(),
    if (kind == 'edit_participation' || kind == 'move_participant')
      payload['id'] as String,
    if (kind == 'set_prices')
      ...((payload['lines'] as List).map((e) => e['id'] as String)),
    if (kind == 'save_booking')
      ...((payload['members'] as List?) ?? []).map((m) => m['id'] as String),
  };
  String get label => switch (kind) {
    'save_person' => 'Карточка человека',
    'merge_people' => 'Объединение карточек',
    'save_booking' => 'Компания участников',
    'edit_participation' => 'Параметры участия',
    'move_participant' => 'Перенос участника на другой выезд',
    'ops_move_escort' => 'Перенос команды сопровождения',
    'set_status' =>
      'Изменение участия · ${participationLabel(payload['status'] as String)}',
    'set_prices' => 'Согласованная стоимость',
    'add_payment' => 'Запись платежа',
    'allocate_payment' => 'Распределение оплаты',
    'correct_payment' => 'Корректировка платежа',
    'ops_setup' => 'Исходные данные парка и работников',
    'ops_resources' => 'Парк или работники',
    'ops_reservation' => 'Бронь лодки, рейс или работа',
    'ops_crew' => 'Место в байдарке',
    'ops_travel' => 'Проезд',
    'ops_presence' => 'Факт посадки / выхода на воду',
    'ops_resolve' => 'Решение расхождения',
    'ops_cabins' => 'Размещение в домиках',
    'ops_settings' => 'Требования к инструкторам',
    _ => 'Изменение',
  };
  JsonMap toJson() => {
    'id': id,
    'team_id': teamId,
    'trip_id': tripId,
    'origin_trip_id': originTripId,
    'kind': kind,
    'payload': payload,
    'expected_version': expectedVersion,
    'dependencies': dependencies,
    'ack_revision': ackRevision,
    'error': error,
  };
  factory PeopleCommand.fromJson(JsonMap map) => PeopleCommand(
    id: map['id'] as String,
    teamId: map['team_id'] as String,
    tripId: map['trip_id'] as String?,
    originTripId: map['origin_trip_id'] as String?,
    kind: map['kind'] as String,
    payload: Map<String, dynamic>.from(map['payload'] as Map),
    expectedVersion: map['expected_version'] as int,
    dependencies: (map['dependencies'] as List).cast<String>(),
    ackRevision: map['ack_revision'] as int?,
    error: map['error'] as String?,
  );
}

class PeopleView {
  const PeopleView({
    this.people = const [],
    this.bookings = const [],
    this.participations = const [],
    this.commands = const [],
    this.ready = false,
    this.confirmedCount = 0,
    this.instructorCount = 0,
    this.syncedAt,
  });
  final List<PersonCard> people;
  final List<Booking> bookings;
  final List<Participation> participations;
  final List<PeopleCommand> commands;
  final bool ready;
  final int confirmedCount;
  final int instructorCount;
  final DateTime? syncedAt;
  PersonCard? person(String id) => people.where((p) => p.id == id).firstOrNull;
}
