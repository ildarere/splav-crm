import 'people_models.dart';

const operationsKinds = {
  'ops_setup',
  'ops_resources',
  'ops_reservation',
  'ops_crew',
  'ops_travel',
  'ops_presence',
  'ops_resolve',
  'ops_settings',
  'ops_cabins',
  'ops_move_escort',
};
const escortRoles = {'water_instructor', 'uaz_driver', 'camp_worker', 'relief'};
const workerRoles = {
  'warehouse': 'Склад',
  'camp_kitchen': 'Кухня лагеря',
  'relief': 'Подмена',
  'uaz_driver': 'Водитель УАЗа',
  'trip_cook': 'Повар на выезде',
  'water_instructor': 'Инструктор на воде',
  'camp_worker': 'Работник лагеря / резерв инструктора',
};
const workerTargets = {
  'uaz_driver': (3, 4),
  'trip_cook': (3, 4),
  'water_instructor': (3, 6),
  'camp_worker': (1, 1),
};
String directionLabel(String value) => value == 'outbound' ? 'Туда' : 'Обратно';
String boatModelLabel(String value) => switch (value) {
  'big' => 'Большая · 3 / 4 места',
  'rf' => 'Каяк РФ · 2 + 1',
  'maigun' => 'Майгун · 2 места',
  _ => 'Другая лодка',
};
String operationsError(String? value) => switch (value) {
  'instructor_transport_excluded' =>
    'Инструкторы не включаются в трансфер участников.',
  'resource_overlap' =>
    'Этот ресурс уже занят в пересекающееся время. Измените время или выберите другой.',
  'invalid_cabins' => 'Проверьте номера, вместимость и состав домиков.',
  'return_unavailable' =>
    'Для этого автобуса недоступен обратный рейс или в нём нет мест.',
  'seat_restriction' =>
    'Для дополнительного места не подходят или не заполнены рост, вес или возраст.',
  'seat_occupied' || 'duplicate_or_occupied' =>
    'Место или инвентарный номер уже заняты. Выберите другой.',
  'physical_seat_occupied' =>
    'На этом месте отмечено фактическое присутствие. Сначала проверьте и исправьте факт.',
  'resource_unavailable' => 'Ресурс отмечен как недоступный.',
  'resource_in_use' =>
    'Ресурс уже забронирован. Его тип и вместимость можно менять после освобождения броней.',
  'reservation_unavailable' => 'Бронь отменена или недоступна.',
  'participation_not_confirmed' =>
    'Сначала подтвердите участие в составе выезда.',
  'passenger_not_assigned' => 'Сначала назначьте человека на место.',
  'passengers_assigned' =>
    'Сначала перенесите назначенных пассажиров: новое число мест, направление или точки им не подходят.',
  'duplicate_person' =>
    'Этот человек уже учтён как участник или работник. Используйте одну запись.',
  'employee_role' => 'У работника нет выбранной специализации.',
  'escort_empty' => 'В выезде нет назначенной команды сопровождения.',
  'escort_already_assigned' =>
    'На выбранный выезд уже назначена команда сопровождения.',
  'already_initialized' =>
    'Исходные данные уже заполнены на другом устройстве.',
  'trip_locked' =>
    'План завершённого или отменённого выезда закрыт для изменений.',
  'presence_missing' => 'Предыдущая отметка присутствия не найдена.',
  _ => peopleErrorLabel(value),
};

List<JsonMap> operationRows(Object? value) => (value as List? ?? [])
    .map((e) => Map<String, dynamic>.from(e as Map))
    .toList();
String subjectKey(String kind, String id) => '$kind:$id';
String travelKey(String kind, String id, String direction) =>
    '$kind:$id:$direction';
String presenceKey(JsonMap value) =>
    '${value['reservation_id']}:${value['subject_kind']}:${value['subject_id']}';

bool boatSeatEligible(
  JsonMap resource,
  int capacity,
  int seat,
  JsonMap parameters,
) {
  if (seat < 1 || seat > capacity) return false;
  num? number(String key) => num.tryParse(parameters[key]?.toString() ?? '');
  final height = number('height_cm'),
      weight = number('weight_kg'),
      age = number('age_years');
  if (capacity == 4) {
    return height != null &&
        height > 0 &&
        height < 130 &&
        age != null &&
        age >= 0 &&
        age < 18;
  }
  if (resource['model'] == 'rf' && seat == 3) {
    return height != null &&
        height > 0 &&
        height <= 155 &&
        weight != null &&
        weight > 0 &&
        weight <= 50;
  }
  return true;
}

String seatDescription(JsonMap resource, int capacity, int seat) =>
    capacity == 4
    ? 'Детское · рост < 130 см'
    : resource['model'] == 'rf' && seat == 3
    ? 'Дополнительное · ≤ 155 см и ≤ 50 кг'
    : 'Обычное место';

class OperationsView {
  const OperationsView({
    this.ready = false,
    this.resources = const [],
    this.reservations = const [],
    this.crews = const [],
    this.travel = const [],
    this.presence = const [],
    this.resolutions = const [],
    this.busy = const [],
    this.history = const [],
    this.settings = const {},
    this.setup,
    this.commands = const [],
    this.server = const {},
  });
  final bool ready;
  final List<JsonMap> resources,
      reservations,
      crews,
      travel,
      presence,
      resolutions,
      busy,
      history;
  final JsonMap settings, server;
  final JsonMap? setup;
  final List<PeopleCommand> commands;
  bool get provisional => commands.isNotEmpty;
  JsonMap? resource(String? id) =>
      resources.where((r) => r['id'] == id).firstOrNull;
  JsonMap? reservation(String? id) =>
      reservations.where((r) => r['id'] == id).firstOrNull;
  JsonMap? crew(String id) =>
      crews.where((r) => r['registration_id'] == id).firstOrNull;
  JsonMap? journey(String kind, String id, String direction) => travel
      .where(
        (r) =>
            r['subject_kind'] == kind &&
            r['subject_id'] == id &&
            r['direction'] == direction,
      )
      .firstOrNull;
  Map<String, JsonMap> get latestPresence => {
    for (final f in presence) presenceKey(f): f,
  };
  JsonMap? fact(String reservation, String kind, String id) =>
      latestPresence['$reservation:$kind:$id'];
  List<JsonMap> bookings(String kind) => reservations
      .where((r) => r['kind'] == kind && r['active'] == true)
      .toList();
  List<Participation> unassigned(PeopleView people) => people.participations
      .where(
        (p) =>
            (p.requestedStatus ?? p.status) == 'confirmed' &&
            p.data['legacy'] != true &&
            crew(p.id)?['reservation_id'] == null,
      )
      .toList();
  int requiredInstructors(PeopleView people) {
    final clients = people.participations
        .where(
          (p) =>
              p.role == 'client' &&
              (p.requestedStatus ?? p.status) == 'confirmed',
        )
        .length;
    return clients == 0
        ? 0
        : clients >= 35 || settings['many_children'] == true
        ? 2
        : 1;
  }

  int instructorsOnWater(PeopleView people) => people.participations
      .where(
        (p) =>
            p.role == 'instructor' &&
            (p.requestedStatus ?? p.status) == 'confirmed' &&
            reservation(crew(p.id)?['reservation_id'] as String?)?['active'] ==
                true,
      )
      .length;
  bool resourceBusy(
    String id,
    DateTime start,
    DateTime end, {
    String? except,
  }) =>
      [
        ...busy,
        for (final b in reservations.where((r) => r['active'] == true))
          {
            ...b,
            'starts_at': b['busy_start'] ?? b['starts_at'],
            'ends_at': b['busy_end'] ?? b['ends_at'],
          },
      ].any(
        (b) =>
            b['resource_id'] == id &&
            b['id'] != except &&
            DateTime.parse(b['starts_at'] as String).isBefore(end) &&
            start.isBefore(DateTime.parse(b['ends_at'] as String)),
      );

  String signature(JsonMap fact, PeopleView people) {
    final booking = reservation(fact['reservation_id'] as String);
    final p = people.participations
        .where((p) => p.id == fact['subject_id'])
        .firstOrNull;
    final t = journey(
      fact['subject_kind'] as String,
      fact['subject_id'] as String,
      booking?['direction'] as String? ?? '',
    );
    final c = crew(fact['subject_id'] as String);
    final status = fact['subject_kind'] == 'participant'
        ? '${p?.requestedStatus ?? p?.status}:${p?.version}'
        : 'employee';
    return '${fact['id']}|$status|${t == null ? 'none' : '${t['mode']}:${t['version']}:${t['reservation_id'] ?? ''}'}'
        '|${c == null ? 'none' : '${c['reservation_id'] ?? ''}:${c['version']}'}|${booking?['active']}:${booking?['version']}';
  }

  List<JsonMap> issues(PeopleView people) {
    final result = <JsonMap>[];
    for (final f in latestPresence.values.where((v) => v['present'] == true)) {
      final b = reservation(f['reservation_id'] as String);
      final p = people.participations
          .where((v) => v.id == f['subject_id'])
          .firstOrNull;
      final plan = b?['kind'] == 'boat'
          ? crew(f['subject_id'] as String)
          : journey(
              f['subject_kind'] as String,
              f['subject_id'] as String,
              b?['direction'] as String? ?? '',
            );
      if (b?['active'] != true ||
          (f['subject_kind'] == 'participant' &&
              (p?.requestedStatus ?? p?.status) != 'confirmed') ||
          plan?['reservation_id'] != b?['id'] ||
          plan?['seat'] != f['seat']) {
        final sign = signature(f, people);
        if (!resolutions.any(
          (r) => r['fact_id'] == f['id'] && r['signature'] == sign,
        )) {
          result.add({...f, 'fact_id': f['id'], 'signature': sign});
        }
      }
    }
    return result;
  }

  static OperationsView project(
    JsonMap? roster,
    List<PeopleCommand> outbox,
    PeopleView people,
  ) {
    final raw = Map<String, dynamic>.from(roster?['operations'] as Map? ?? {});
    final resources = {
      for (final r in operationRows(raw['resources'])) r['id'] as String: r,
    };
    final bookings = {
      for (final r in operationRows(raw['reservations'])) r['id'] as String: r,
    };
    final crews = {
      for (final r in operationRows(raw['crews']))
        r['registration_id'] as String: r,
    };
    final travel = {
      for (final r in operationRows(raw['travel']))
        travelKey(
          r['subject_kind'] as String,
          r['subject_id'] as String,
          r['direction'] as String,
        ): r,
    };
    final presence = {
      for (final r in operationRows(raw['presence'])) r['id'] as String: r,
    };
    final resolutions = {
      for (final r in operationRows(raw['resolutions'])) r['id'] as String: r,
    };
    var setup = raw['setup'] as JsonMap?,
        settings = Map<String, dynamic>.from(raw['settings'] as Map? ?? {});
    final tripId = roster?['trip_id'], teamId = roster?['team_id'];
    final commands = outbox
        .where((c) => operationsKinds.contains(c.kind) && c.teamId == teamId)
        .toList();
    for (final command in commands) {
      final x = command.payload;
      final flags = {'pending': true, 'conflict': command.error != null};
      if (command.kind == 'ops_setup' || command.kind == 'ops_resources') {
        for (final r in operationRows(x['items'])) {
          resources[r['id'] as String] = {
            ...r,
            'version': (r['version'] as int? ?? 0) + 1,
            ...flags,
          };
        }
        if (command.kind == 'ops_setup') {
          setup = Map<String, dynamic>.from(x['reference'] as Map? ?? {});
        }
      }
      if (command.tripId != tripId) continue;
      final version = command.expectedVersion + 1;
      if (command.kind == 'ops_reservation') {
        final start = DateTime.parse(
          x['starts_at'] as String,
        ).subtract(Duration(minutes: x['prep_minutes'] as int? ?? 0));
        final end = DateTime.parse(
          x['ends_at'] as String,
        ).add(Duration(minutes: x['return_minutes'] as int? ?? 0));
        bookings[x['id'] as String] = {
          ...x,
          'version': version,
          'busy_start': start.toUtc().toIso8601String(),
          'busy_end': end.toUtc().toIso8601String(),
          ...flags,
        };
        if (x['active'] == false) {
          for (final c in crews.values.where(
            (v) => v['reservation_id'] == x['id'],
          )) {
            c.addAll({
              'reservation_id': null,
              'seat': null,
              'version': (c['version'] as int) + 1,
              ...flags,
            });
          }
          for (final t in travel.values.where(
            (v) => v['reservation_id'] == x['id'],
          )) {
            t.addAll({
              'mode': 'unset',
              'reservation_id': null,
              'seat': null,
              'point_id': null,
              'version': (t['version'] as int) + 1,
              ...flags,
            });
          }
        }
      }
      if (command.kind == 'ops_crew') {
        if (x['swap_id'] is String) {
          final old = crews[x['subject_id']];
          final other = crews[x['swap_id']];
          if (old != null && other != null) {
            crews[x['swap_id'] as String] = {
              ...other,
              'reservation_id': old['reservation_id'],
              'seat': old['seat'],
              'version': (other['version'] as int) + 1,
              ...flags,
            };
          }
        }

        crews[x['subject_id'] as String] = {
          ...x,
          'registration_id': x['subject_id'],
          'version': version,
          ...flags,
        };
      }
      if (command.kind == 'ops_travel') {
        travel[travelKey(
          x['subject_kind'] as String,
          x['subject_id'] as String,
          x['direction'] as String,
        )] = {
          ...x,
          'version': version,
          ...flags,
        };
      }
      if (command.kind == 'ops_settings') {
        settings = {...settings, ...x, 'version': version, ...flags};
      }
      if (command.kind == 'ops_cabins') {
        if (command.error != null) continue;
        settings = {...settings, 'cabins': x, 'cabins_version': version};
      }
      if (command.kind == 'ops_presence' && !presence.containsKey(x['id'])) {
        final booking = bookings[x['reservation_id']];
        Object? seat;
        if (x['present'] == true) {
          if (booking?['kind'] == 'boat') {
            seat = crews[x['subject_id']]?['seat'];
          } else {
            final key = travelKey(
              x['subject_kind'] as String,
              x['subject_id'] as String,
              booking?['direction'] as String? ?? '',
            );
            seat = travel[key]?['seat'];
          }
        } else {
          seat = presence.values
              .where((f) => presenceKey(f) == presenceKey(x))
              .lastOrNull?['seat'];
        }
        presence[x['id'] as String] = {...x, 'seat': seat, ...flags};
      }
      if (command.kind == 'ops_resolve') {
        resolutions[x['id'] as String] = {...x, ...flags};
        final source = presence[x['fact_id']];
        if (x['decision'] == 'error' &&
            source != null &&
            !presence.containsKey(x['correction_id'])) {
          presence[x['correction_id'] as String] = {
            ...source,
            'id': x['correction_id'],
            'present': false,
            'reason': x['reason'],
            ...flags,
          };
        }
      }
    }
    // Apply provisional cancellations to plans, never to physical facts.
    for (final p in people.participations.where(
      (p) => (p.requestedStatus ?? p.status) != 'confirmed',
    )) {
      final c = crews[p.id];
      if (c?['reservation_id'] != null) {
        c!.addAll({
          'reservation_id': null,
          'seat': null,
          'version': (c['version'] as int) + 1,
          'pending': p.pending,
        });
      }
      for (final t in travel.values.where(
        (v) =>
            v['subject_kind'] == 'participant' &&
            v['subject_id'] == p.id &&
            v['mode'] != 'unset',
      )) {
        t.addAll({
          'mode': 'unset',
          'reservation_id': null,
          'seat': null,
          'version': (t['version'] as int) + 1,
          'pending': p.pending,
        });
      }
    }
    for (final p in people.participations.where(
      (p) => (p.requestedStatus ?? p.status) == 'confirmed',
    )) {
      final c = crews[p.id], b = bookings[crews[p.id]?['reservation_id']];
      final r = resources[b?['resource_id']];
      if (c != null &&
          b != null &&
          r != null &&
          !boatSeatEligible(
            r,
            b['capacity'] as int,
            c['seat'] as int,
            p.parameters,
          )) {
        c.addAll({
          'reservation_id': null,
          'seat': null,
          'version': (c['version'] as int) + 1,
          'pending': p.pending,
        });
      }
    }
    return OperationsView(
      ready: roster?['operations_protocol'] == 1,
      resources: resources.values.toList(),
      reservations: bookings.values.toList(),
      crews: crews.values.toList(),
      travel: travel.values.toList(),
      presence: presence.values.toList(),
      resolutions: resolutions.values.toList(),
      busy: operationRows(raw['busy']),
      history: operationRows(raw['history']),
      settings: settings,
      setup: setup,
      commands: commands,
      server: raw,
    );
  }
}

JsonMap defaultOperationsSetup(String Function() id) {
  JsonMap resource(
    String kind,
    String name,
    String code,
    String model,
    int capacity, {
    List<String> roles = const [],
  }) => {
    'id': id(),
    'kind': kind,
    'name': name,
    'code': code,
    'model': model,
    'capacity': capacity,
    'roles': roles,
    'available': true,
    'version': 0,
    'notes': '',
  };
  return {
    'items': [
      resource('boat', 'Большая байдарка 01', 'Б-01', 'big', 4),
      resource('boat', 'Большая байдарка 02', 'Б-02', 'big', 4),
      resource('vehicle', 'Наш автобус', 'АВТ-30', 'own_bus', 30),
      resource('vehicle', 'Второй автобус', 'АВТ-2', 'secondary_bus', 20),
      resource('vehicle', 'Такси', 'ТАКСИ-1', 'taxi', 4),
      resource(
        'employee',
        'Лиза',
        'СКЛАД',
        'employee',
        0,
        roles: ['warehouse'],
      ),
      resource(
        'employee',
        'Анна Орлова',
        'КУХНЯ',
        'employee',
        0,
        roles: ['camp_kitchen'],
      ),
      resource(
        'employee',
        'Варя',
        'ПОДМЕНА',
        'employee',
        0,
        roles: ['warehouse', 'camp_kitchen', 'relief'],
      ),
    ],
    'reference': {
      'rf_min': 20,
      'rf_max': 25,
      'maigun_min': 21,
      'pool_targets': {
        for (final e in workerTargets.entries)
          e.key: {'min': e.value.$1, 'max': e.value.$2},
      },
      'note':
          'Количество Каяк РФ и Майгун нужно уточнить перед внесением в парк.',
    },
  };
}
