import 'package:drift/native.dart';
import 'package:splav/core/prototype.dart';
import '../stage1_fixture.dart';

class UnusedOperationsStage implements Stage1Api {
  @override
  Future<void> prepare() async {}
  @override
  Future<TripCatalog> catalog() => throw UnimplementedError();
  @override
  Future<TripSaveResult> saveTrip(TripCommand c) => throw UnimplementedError();
  @override
  Future<TripRoute> createRoute(RouteCommand c) => throw UnimplementedError();
  @override
  PrototypeApi groupApi(String id) => throw UnimplementedError();
}

class UnusedOperationsPeople implements PeopleApi {
  @override
  Future<JsonMap> catalog() => throw UnimplementedError();
  @override
  Future<JsonMap> roster(String id, int cursor) => throw UnimplementedError();
  @override
  Future<JsonMap> submit(PeopleCommand c) => throw UnimplementedError();
}

Future<Stage1Controller> operationsFixture({
  PrototypeDatabase? database,
  bool seed = true,
}) async {
  final db = database ?? PrototypeDatabase(NativeDatabase.memory());
  if (seed) {
    await db.cacheCatalog(
      TripCatalog(
        teams: const [TripTeam(id: demoTeam, name: 'Команда', role: 'admin')],
        routes: const [
          TripRoute(id: demoRoute, teamId: demoTeam, name: 'Река'),
        ],
        trips: [serverTrip(demoGroup, draft(capacity: 35))],
      ),
    );
    JsonMap resource(
      String id,
      String kind,
      String name,
      String model,
      int cap, {
      List<String> roles = const [],
    }) => {
      'id': id,
      'team_id': demoTeam,
      'kind': kind,
      'name': name,
      'code': id,
      'model': model,
      'capacity': cap,
      'available': true,
      'roles': roles,
      'notes': '',
      'version': 1,
    };
    JsonMap booking(
      String id,
      String kind,
      String resource,
      int cap, {
      String direction = 'outbound',
    }) => {
      'id': id,
      'kind': kind,
      'trip_id': demoGroup,
      'resource_id': resource,
      'capacity': cap,
      'active': true,
      'version': 1,
      'starts_at': '2027-05-12T06:00:00Z',
      'ends_at': '2027-05-12T14:00:00Z',
      'busy_start': '2027-05-12T06:00:00Z',
      'busy_end': '2027-05-12T14:00:00Z',
      'prep_minutes': 0,
      'return_minutes': 0,
      'direction': direction,
      'points': [
        {'id': 'bridge', 'name': 'Мост'},
      ],
      'notes': '',
    };
    await db.cacheRoster({
      'trip_id': demoGroup,
      'team_id': demoTeam,
      'revision': 1,
      'finance_protocol': 1,
      'payments': [],
      'people': [
        for (var i = 0; i < 4; i++)
          {
            'id': 'person$i',
            'team_id': demoTeam,
            'name': ['Взрослый', 'Ребёнок', 'Невысокий', 'Инструктор'][i],
            'version': 1,
          },
      ],
      'bookings': [
        {
          'id': 'family',
          'trip_id': demoGroup,
          'contact_name': 'Семья',
          'version': 1,
        },
        {
          'id': 'staff',
          'trip_id': demoGroup,
          'contact_name': 'Инструктор',
          'version': 1,
        },
      ],
      'participations': [
        for (var i = 0; i < 4; i++)
          {
            'id': 'p$i',
            'trip_id': demoGroup,
            'person_id': 'person$i',
            'booking_id': i == 3 ? 'staff' : 'family',
            'role': i == 3 ? 'instructor' : 'client',
            'status': 'confirmed',
            'agreed_price_kopeks': i == 3 ? 0 : 100000,
            'version': 1,
            'parameters': [
              {'height_cm': 185, 'weight_kg': 90, 'age_years': 35},
              {'height_cm': 130, 'weight_kg': 30, 'age_years': 8},
              {'height_cm': 155, 'weight_kg': 50, 'age_years': 30},
              {'height_cm': 175, 'weight_kg': 75, 'age_years': 35},
            ][i],
          },
      ],
      'operations_protocol': 1,
      'operations': {
        'setup': {'rf_min': 20, 'rf_max': 25},
        'settings': {'many_children': false, 'version': 1},
        'resources': [
          resource('big', 'boat', 'Большая 01', 'big', 4),
          resource('rf', 'boat', 'Каяк РФ 01', 'rf', 3),
          resource('bus', 'vehicle', 'Наш автобус', 'own_bus', 30),
          resource(
            'worker',
            'employee',
            'Лиза',
            'employee',
            0,
            roles: ['warehouse'],
          ),
        ],
        'reservations': [
          booking('bigBooking', 'boat', 'big', 4),
          booking('rfBooking', 'boat', 'rf', 3),
          booking('ride', 'ride', 'bus', 30),
        ],
        'crews': [
          {
            'registration_id': 'p0',
            'reservation_id': 'bigBooking',
            'seat': 1,
            'version': 1,
          },
          {
            'registration_id': 'p1',
            'reservation_id': 'bigBooking',
            'seat': 4,
            'version': 1,
          },
          {
            'registration_id': 'p3',
            'reservation_id': 'rfBooking',
            'seat': 1,
            'version': 1,
          },
        ],
        'travel': [
          for (final i in [0, 3])
            {
              'id': 'travel$i',
              'subject_kind': 'participant',
              'subject_id': 'p$i',
              'direction': 'outbound',
              'mode': 'bus',
              'reservation_id': 'ride',
              'seat': i == 0 ? 1 : 2,
              'point_id': 'bridge',
              'version': 1,
            },
          {
            'id': 'return0',
            'subject_kind': 'participant',
            'subject_id': 'p0',
            'direction': 'return',
            'mode': 'self',
            'version': 1,
            'reservation_id': null,
            'seat': null,
          },
        ],
        'presence': [
          {
            'id': 'fact0',
            'reservation_id': 'ride',
            'subject_kind': 'participant',
            'subject_id': 'p0',
            'present': true,
            'seat': 1,
            'sequence': 1,
            'occurred_at': '2027-05-12T05:30:00Z',
            'device_id': 'fixture',
            'author_id': 'organizer',
          },
        ],
        'busy': [],
        'resolutions': [],
        'history': [],
        'issues': [],
      },
    });
  }
  final c = Stage1Controller(
    db,
    UnusedOperationsStage(),
    peopleApi: UnusedOperationsPeople(),
    retryInterval: null,
  );
  await c.initialize(autoSync: false);
  c.setOffline(true);
  return c;
}
