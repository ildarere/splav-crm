import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/core/prototype.dart';
import 'package:supabase/supabase.dart';
import 'package:uuid/uuid.dart';

const operationsTestTeam = '45000000-0000-4000-8000-000000000001';
const operationsTestRoute = '45000000-0000-4000-8000-000000000002';

class _OperationFaults implements PeopleApi {
  _OperationFaults(this.api);
  final PeopleApi api;
  bool losePresenceReply = true,
      interruptResolution = false,
      failSnapshot = false;
  final presenceOperations = <String>[], resolutions = <String>[];
  @override
  Future<JsonMap> catalog() => api.catalog();
  @override
  Future<JsonMap> roster(String id, int cursor) async {
    if (failSnapshot) {
      failSnapshot = false;
      throw const SocketException('Snapshot lost after server acknowledgement');
    }
    return api.roster(id, cursor);
  }

  @override
  Future<JsonMap> submit(PeopleCommand command) async {
    final result = await api.submit(command);
    if (command.kind == 'ops_presence') {
      presenceOperations.add(command.id);
      if (losePresenceReply) {
        losePresenceReply = false;
        throw const SocketException('Committed boarding response lost');
      }
    }
    if (command.kind == 'ops_resolve') {
      resolutions.add(command.id);
      if (interruptResolution) {
        interruptResolution = false;
        failSnapshot = true;
      }
    }
    return result;
  }
}

Future<void> operationsScenario({
  required String url,
  required String key,
  required Future<PrototypeDatabase> Function(String) openDatabase,
  Future<void> Function(Stage1Controller)? inspect,
}) async {
  const uuid = Uuid();
  final tag = uuid.v4().substring(0, 8);
  final warning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final ca = SupabaseClient(
    url,
    key,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final cb = SupabaseClient(
    url,
    key,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  Stage1Controller? currentA, currentB;
  try {
    for (final client in [ca, cb]) {
      await client.auth.signInWithPassword(
        email: 'organizer-a@example.com',
        password: 'local-splav-demo-2026',
      );
    }
    final faults = _OperationFaults(SupabasePeopleApi(ca));
    Future<Stage1Controller> open(
      String profile,
      SupabaseClient client,
      PeopleApi api,
    ) async {
      final db = await openDatabase(profile);
      await db.bindAccountOwner(client.auth.currentUser!.id);
      final c = Stage1Controller(
        db,
        SupabaseStage1Api(client: client, prepare: () async {}),
        peopleApi: api,
        retryInterval: null,
      );
      await c.initialize(autoSync: false);
      return c;
    }

    var a = await open('a', ca, faults);
    currentA = a;
    final b = await open('b', cb, SupabasePeopleApi(cb));
    currentB = b;
    await a.sync();
    expect(a.error, isNull);
    expect(
      a.teams.any((t) => t.id == operationsTestTeam),
      isTrue,
      reason:
          'Сначала выполните scripts/stage45_acceptance.py для подготовки отдельной тестовой команды.',
    );
    a.setOffline(true);
    final trip = await a.saveTrip(
      TripDraft(
        teamId: operationsTestTeam,
        title: 'Лодки и трансфер $tag',
        routeId: operationsTestRoute,
        startsAt: DateTime.utc(2039, 8, 1, 6),
        endsAt: DateTime.utc(2039, 8, 2, 14),
        timeZone: 'Europe/Saratov',
        meetingPoint: 'Причал',
        meetingAt: DateTime.utc(2039, 8, 1, 5),
        responsibleNames: 'Тест',
        capacity: 35,
        basePriceKopecks: 100000,
        notes: 'Вымышленные данные этапов 4–5',
        status: 'open',
      ),
    );
    a.setOffline(false);
    await a.sync();
    expect(a.error, isNull);
    expect(a.operationsView.ready, isTrue);
    final rf = uuid.v4(), big = uuid.v4(), bus = uuid.v4(), worker = uuid.v4();
    final rfBooking = uuid.v4(),
        bigBooking = uuid.v4(),
        ride = uuid.v4(),
        returnRide = uuid.v4();
    final parts = [for (var i = 0; i < 4; i++) uuid.v4()],
        persons = [for (var i = 0; i < 4; i++) uuid.v4()];
    JsonMap resource(String id, String kind, String model, int capacity) => {
      'id': id,
      'kind': kind,
      'name': 'Тест $model $tag',
      'code': '$tag-$model',
      'model': model,
      'capacity': capacity,
      'roles': kind == 'employee' ? ['uaz_driver', 'trip_cook'] : [],
      'available': true,
      'version': 0,
      'notes': '',
    };
    a.setOffline(true);
    await a.queueOperations('ops_resources', {
      'items': [
        resource(rf, 'boat', 'rf', 3),
        resource(big, 'boat', 'big', 4),
        resource(bus, 'vehicle', 'own_bus', 30),
        resource(worker, 'employee', 'employee', 0),
      ],
    });
    final bookingId = uuid.v4();
    await a.saveBooking(
      {
        'id': bookingId,
        'contact_name': 'Тестовая семья $tag',
        'members': [
          for (var i = 0; i < 4; i++)
            {
              'id': parts[i],
              'person_id': persons[i],
              'role': i == 3 ? 'instructor' : 'client',
              'parameters': [
                {'height_cm': 180, 'weight_kg': 80, 'age_years': 35},
                {'height_cm': 130, 'weight_kg': 30, 'age_years': 8},
                {'height_cm': 155, 'weight_kg': 50, 'age_years': 30},
                {'height_cm': 175, 'weight_kg': 75, 'age_years': 35},
              ][i],
            },
        ],
      },
      newPeople: [
        for (var i = 0; i < 4; i++)
          {'id': persons[i], 'name': 'Участник $i $tag'},
      ],
    );
    await a.setParticipationStatus(parts.toSet(), 'confirmed');
    JsonMap reserve(
      String id,
      String resource,
      String kind,
      int capacity, {
      String direction = 'outbound',
    }) => {
      'id': id,
      'resource_id': resource,
      'kind': kind,
      'capacity': capacity,
      'active': true,
      'prep_minutes': 0,
      'return_minutes': 0,
      'starts_at':
          (kind == 'ride'
                  ? (direction == 'outbound'
                        ? DateTime.utc(2039, 8, 1, 5)
                        : DateTime.utc(2039, 8, 2, 14))
                  : DateTime.utc(2039, 8, 1, 6))
              .toIso8601String(),
      'ends_at':
          (kind == 'ride'
                  ? (direction == 'outbound'
                        ? DateTime.utc(2039, 8, 1, 6)
                        : DateTime.utc(2039, 8, 2, 15))
                  : DateTime.utc(2039, 8, 2, 14))
              .toIso8601String(),
      'direction': direction,
      'points': [
        {'id': 'pier', 'name': 'Причал'},
      ],
      'notes': '',
    };
    await a.queueOperations(
      'ops_reservation',
      reserve(rfBooking, rf, 'boat', 3),
    );
    await a.queueOperations(
      'ops_reservation',
      reserve(bigBooking, big, 'boat', 4),
    );
    await a.queueOperations('ops_reservation', reserve(ride, bus, 'ride', 30));
    await a.queueOperations(
      'ops_reservation',
      reserve(returnRide, bus, 'ride', 30, direction: 'return'),
    );
    await a.queueOperations('ops_reservation', {
      ...reserve(uuid.v4(), worker, 'duty', 1),
      'role': 'uaz_driver',
    });
    for (var i = 0; i < 4; i++) {
      await a.queueOperations('ops_crew', {
        'subject_kind': 'participant',
        'subject_id': parts[i],
        'reservation_id': i < 2 ? bigBooking : rfBooking,
        'seat': i == 0
            ? 1
            : i == 1
            ? 4
            : i == 2
            ? 3
            : 1,
      });
      await a.queueOperations('ops_travel', {
        'subject_kind': 'participant',
        'subject_id': parts[i],
        'direction': 'outbound',
        'mode': 'bus',
        'reservation_id': ride,
        'seat': i + 1,
        'point_id': 'pier',
      });
      await a.queueOperations('ops_travel', {
        'subject_kind': 'participant',
        'subject_id': parts[i],
        'direction': 'return',
        'mode': i == 0 ? 'self' : 'bus',
        'reservation_id': i == 0 ? null : returnRide,
        'seat': i == 0 ? null : i,
        'point_id': i == 0 ? null : 'pier',
      });
    }
    await a.queueOperations('ops_travel', {
      'subject_kind': 'employee',
      'subject_id': worker,
      'direction': 'outbound',
      'mode': 'bus',
      'reservation_id': ride,
      'seat': 5,
      'point_id': 'pier',
    });
    await a.queueFinance('add_payment', {
      'booking_id': bookingId,
      'amount_kopeks': 50000,
      'direction': 'income',
      'method': 'cash',
      'occurred_at': DateTime.now().toUtc().toIso8601String(),
      'allocations': [
        {'participation_id': parts[0], 'amount_kopeks': 50000},
      ],
    });
    await a.queueOperations('ops_presence', {
      'subject_kind': 'participant',
      'subject_id': parts[0],
      'reservation_id': ride,
      'present': true,
    });
    final queue = a.peopleView.commands.map((c) => c.id).toList();
    expect(a.operationsView.unassigned(a.peopleView), isEmpty);
    await a.close();
    a = await open('a', ca, faults);
    currentA = a;
    a.setOffline(true);
    await a.chooseTrip(trip);
    expect(a.peopleView.commands.map((c) => c.id), queue);
    expect(
      a.operationsView.fact(ride, 'participant', parts[0])?['present'],
      isTrue,
    );
    a.setOffline(false);
    await a.sync();
    expect(a.error, isNotNull);
    expect(faults.presenceOperations, hasLength(1));
    await a.close();
    a = await open('a', ca, faults);
    currentA = a;
    await a.chooseTrip(trip);
    await a.sync();
    expect(a.error, isNull);
    expect(a.operationsView.commands, isEmpty);
    expect(a.financeView.net(bookingId), 50000);
    expect(faults.presenceOperations, [
      faults.presenceOperations.first,
      faults.presenceOperations.first,
    ]);
    expect(a.operationsView.presence, hasLength(1));
    await b.sync();
    await b.chooseTrip(trip);
    await b.sync();
    expect(b.error, isNull);
    // Two stale clients move different people into the same last empty seat.
    a.setOffline(true);
    b.setOffline(true);
    for (final pair in [(a, 1), (b, 2)]) {
      await pair.$1.queueOperations(
        'ops_crew',
        {
          'subject_kind': 'participant',
          'subject_id': parts[pair.$2],
          'reservation_id': bigBooking,
          'seat': 2,
        },
        expectedVersion:
            pair.$1.operationsView.crew(parts[pair.$2])!['version'] as int,
      );
    }
    a.setOffline(false);
    b.setOffline(false);
    await Future.wait([a.sync(), b.sync()]);
    final conflicts = [
      ...a.operationsView.commands,
      ...b.operationsView.commands,
    ].where((c) => c.error != null).toList();
    expect(conflicts, hasLength(1));
    expect(conflicts.single.error, 'seat_occupied');
    for (final c in [a, b]) {
      for (final command
          in c.operationsView.commands.where((q) => q.error != null).toList()) {
        await c.discardPeopleChange(command.id);
      }
    }
    await Future.wait([a.sync(), b.sync()]);
    expect(
      a.operationsView.crews.where(
        (c) => c['reservation_id'] == bigBooking && c['seat'] == 2,
      ),
      hasLength(1),
    );
    final adult = b.peopleView.participations.firstWhere(
      (p) => p.id == parts[0],
    );
    expect(adult.status, 'confirmed');
    b.setOffline(true);
    await b.setParticipationStatus({adult.id}, 'cancelled');
    b.setOffline(false);
    await b.sync();
    expect(b.error, isNull);
    await a.sync();
    expect(a.error, isNull);
    expect(a.operationsView.crew(parts[0])?['reservation_id'], isNull);
    expect(
      a.operationsView.journey('participant', parts[0], 'outbound')?['mode'],
      'unset',
    );
    final issue = a.operationsView.issues(a.peopleView).single;
    expect(
      a.operationsView.fact(ride, 'participant', parts[0])?['present'],
      isTrue,
    );
    a.setOffline(true);
    if (inspect != null) await inspect(a);
    faults.interruptResolution = true;
    await a.queueOperations('ops_resolve', {
      'fact_id': issue['fact_id'],
      'signature': issue['signature'],
      'decision': 'error',
      'reason': 'Проверено организатором: ошибочная отметка',
    });
    a.setOffline(false);
    await a.sync();
    expect(a.error, isNotNull);
    expect(a.operationsView.commands.single.ackRevision, isNotNull);
    await a.close();
    a = await open('a', ca, faults);
    currentA = a;
    a.setOffline(true);
    await a.chooseTrip(trip);
    expect(a.operationsView.commands.single.ackRevision, isNotNull);
    a.setOffline(false);
    await a.sync();
    expect(a.error, isNull);
    expect(a.operationsView.commands, isEmpty);
    expect(faults.resolutions, hasLength(1));
    expect(a.operationsView.presence, hasLength(2));
    expect(a.operationsView.issues(a.peopleView), isEmpty);
    expect(a.financeView.net(bookingId), 50000);
    await b.sync();
    expect(b.operationsView.presence, hasLength(2));
    expect(b.operationsView.issues(b.peopleView), isEmpty);
    expect(
      a.operationsView.journey('participant', parts[0], 'return')?['mode'],
      'unset',
    ); // Cancellation frees both independent plans.
  } finally {
    await currentA?.clearAccountData();
    await currentB?.clearAccountData();
    await currentA?.close();
    await currentB?.close();
    await ca.dispose();
    await cb.dispose();
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = warning;
  }
}
