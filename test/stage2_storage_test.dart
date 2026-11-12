import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:splav/core/prototype.dart';
import 'stage1_fixture.dart';

const _person = <String, dynamic>{
  'id': 'person',
  'team_id': demoTeam,
  'name': 'Человек',
  'version': 1,
};
JsonMap _roster({
  int revision = 10,
  String status = 'application',
  int version = 1,
}) => {
  'trip_id': demoGroup,
  'team_id': demoTeam,
  'revision': revision,
  'people': [_person],
  'bookings': [
    {
      'id': 'booking',
      'trip_id': demoGroup,
      'contact_name': 'Контакт',
      'version': 1,
    },
  ],
  'participations': [
    {
      'id': 'participation',
      'person_id': 'person',
      'trip_id': demoGroup,
      'booking_id': 'booking',
      'role': 'client',
      'status': status,
      'version': version,
      'parameters': <String, dynamic>{},
    },
  ],
};
TripCatalog _catalog({bool visible = true}) => TripCatalog(
  teams: const [TripTeam(id: demoTeam, name: 'Команда', role: 'organizer')],
  routes: const [TripRoute(id: demoRoute, teamId: demoTeam, name: 'Река')],
  trips: visible ? [serverTrip(demoGroup, draft())] : [],
);

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('splav-stage2-storage-');
    final old = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = old);
  });
  tearDown(() => directory.delete(recursive: true));
  PrototypeDatabase open() {
    final db = PrototypeDatabase(
      NativeDatabase(File('${directory.path}/client.sqlite')),
    );
    addTearDown(db.close);
    return db;
  }

  test('v2 upgrade retains every old queue and displays offline records', () async {
    final file = File('${directory.path}/client.sqlite');
    createV1Fixture(file);
    var db = open();
    await db.cacheCatalog(_catalog());
    await db.queueTrip(
      TripCommand(
        operationId: 'metadata-op',
        tripId: demoGroup,
        expectedVersion: 1,
        draft: draft(title: 'Местная правка'),
      ),
    );
    await db.queueRoute(
      const RouteCommand(
        operationId: 'route-op',
        route: TripRoute(id: 'new-route', teamId: demoTeam, name: 'Новая река'),
      ),
    );
    await db.close();
    final previous = sqlite3.open(file.path);
    // Produce exactly the persisted v2 schema, with all three queues populated.
    previous.execute(
      'DROP TABLE person_cards; DROP TABLE roster_cache; DROP TABLE people_outbox; PRAGMA user_version=2;',
    );
    previous.close();
    db = open();
    final view = await db.readPeople(demoGroup);
    expect(view.ready, isTrue);
    expect(view.participations.single.pending, isTrue);
    expect(view.people.single.name, 'Старая очередь');
    expect(
      (await db.pendingCommands(demoGroup)).single.operationId,
      '00000000-0000-4000-8000-000000000093',
    );
    expect((await db.tripCommands()).single.operationId, 'metadata-op');
    expect((await db.routeCommands()).single.operationId, 'route-op');
    final old = (await db.pendingCommands(demoGroup)).single;
    await db.reject(old, 'capacity_reached');
    await db.cacheRoster({
      'trip_id': demoGroup,
      'team_id': demoTeam,
      'revision': 10,
      'people': [],
      'bookings': [],
      'participations': [],
    });
    final retained = await db.readPeople(demoGroup);
    expect(retained.participations.single.data['legacy_rejection'], isTrue);
    expect(retained.people.single.name, 'Старая очередь');
    await db.close();
    db = open();
    expect(
      (await db.readPeople(demoGroup)).participations.single.id,
      old.registrationId,
    );
  });

  test(
    'ack survives restart; snapshot, cursor and queue retirement are atomic',
    () async {
      var db = open();
      await db.cacheCatalog(_catalog());
      await db.cacheRoster(_roster());
      const status = PeopleCommand(
        id: 'status',
        teamId: demoTeam,
        tripId: demoGroup,
        kind: 'set_status',
        payload: {
          'ids': ['participation'],
          'status': 'confirmed',
          'versions': {'participation': 1},
        },
      );
      const dependent = PeopleCommand(
        id: 'parameters',
        teamId: demoTeam,
        tripId: demoGroup,
        kind: 'edit_participation',
        payload: {
          'id': 'participation',
          'role': 'client',
          'parameters': {'height_cm': 180},
        },
        expectedVersion: 2,
        dependencies: ['status'],
      );
      await db.queuePeople(status);
      await db.queuePeople(dependent);
      await db.recordPeopleResult(status, {
        'status': 'accepted',
        'revision': 11,
      });
      await db.close();
      db = open();
      expect((await db.peopleCommands()).first.ackRevision, 11);
      expect(await db.nextPeopleCommand(), isNull);
      expect((await db.readPeople(demoGroup)).confirmedCount, 0);
      final broken = {
        ..._roster(revision: 11, status: 'confirmed', version: 2),
        'people': [
          {'name': 'No ID'},
        ],
      };
      await expectLater(db.cacheRoster(broken), throwsA(anything));
      expect(await db.rosterRevision(demoGroup), 10);
      expect(await db.peopleCommands(), hasLength(2));
      await db.cacheRoster(
        _roster(revision: 11, status: 'confirmed', version: 2),
      );
      expect((await db.peopleCommands()).single.id, 'parameters');
      expect((await db.nextPeopleCommand())?.id, 'parameters');
      expect((await db.readPeople(demoGroup)).confirmedCount, 1);
    },
  );

  test(
    'conflicted dependencies wait while an unrelated command can proceed',
    () async {
      final db = open();
      const first = PeopleCommand(
        id: 'person-op',
        teamId: demoTeam,
        kind: 'save_person',
        payload: {'id': 'a', 'name': 'А'},
      );
      await db.queuePeople(first);
      await db.recordPeopleResult(first, {'reason': 'version_conflict'});
      await db.queuePeople(
        const PeopleCommand(
          id: 'booking-op',
          teamId: demoTeam,
          tripId: demoGroup,
          kind: 'save_booking',
          payload: {'id': 'booking', 'members': []},
          dependencies: ['person-op'],
        ),
      );
      await db.queuePeople(
        const PeopleCommand(
          id: 'status-op',
          teamId: demoTeam,
          tripId: demoGroup,
          kind: 'set_status',
          payload: {'ids': [], 'status': 'confirmed'},
          dependencies: ['booking-op'],
        ),
      );
      await db.queuePeople(
        const PeopleCommand(
          id: 'other',
          teamId: demoTeam,
          kind: 'save_person',
          payload: {'id': 'b', 'name': 'Б'},
        ),
      );
      expect((await db.nextPeopleCommand())?.id, 'other');
      await db.discardPeople('person-op');
      expect((await db.peopleCommands()).map((c) => c.id), ['other']);
    },
  );

  test(
    'revocation removes trip, roster, contacts and family drafts before any push',
    () async {
      final db = open(), server = _StageApi(), people = _PeopleApi();
      await db.bindAccountOwner('organizer');
      await db.cacheCatalog(_catalog());
      await db.requestDownload(demoGroup, true);
      await db.cacheRoster(_roster());
      final controller = Stage1Controller(
        db,
        server,
        peopleApi: people,
        retryInterval: null,
      );
      addTearDown(controller.close);
      await controller.initialize(autoSync: false);
      controller.setOffline(true);
      await controller.saveBooking(
        {
          'contact_name': 'Семья',
          'contact_person_id': 'new',
          'members': [
            {
              'id': 'new-participation',
              'person_id': 'new',
              'role': 'client',
              'parameters': <String, dynamic>{},
            },
          ],
        },
        newPeople: [
          {'id': 'new', 'name': 'Новый человек'},
        ],
      );
      expect(controller.peopleView.commands, hasLength(2));
      server.visible = false;
      people.visible = false;
      controller.setOffline(false);
      await controller.sync();
      expect(controller.trips, isEmpty);
      expect(controller.peopleView.people, isEmpty);
      expect(controller.peopleView.commands, isEmpty);
      expect(people.submissions, 0);
      expect(await db.serverRoster(demoGroup), isNull);
    },
  );

  test(
    'an unavailable referenced person becomes a conflict without deleting a valid trip',
    () async {
      final db = open(), server = _StageApi(), people = _PeopleApi();
      await db.cacheCatalog(_catalog());
      await db.requestDownload(demoGroup, true);
      await db.cacheRoster(_roster());
      final controller = Stage1Controller(
        db,
        server,
        peopleApi: people,
        retryInterval: null,
      );
      addTearDown(controller.close);
      await controller.initialize(autoSync: false);
      controller.setOffline(true);
      await controller.saveBooking({
        'contact_name': 'Контакт',
        'members': [
          {
            'id': 'new-id',
            'person_id': 'inaccessible',
            'role': 'client',
            'parameters': <String, dynamic>{},
          },
        ],
      });
      controller.setOffline(false);
      await controller.sync();
      expect(controller.trips.single.id, demoGroup);
      expect(controller.peopleView.ready, isTrue);
      expect(controller.peopleView.commands.single.error, 'access_denied');
      expect(people.submissions, 1);
    },
  );

  test(
    'changing account UUID clears new directory, snapshots and queue',
    () async {
      final db = open();
      await db.bindAccountOwner('old');
      await db.cacheCatalog(_catalog());
      await db.cacheRoster(_roster());
      await db.queuePeople(
        const PeopleCommand(
          id: 'new',
          teamId: demoTeam,
          kind: 'save_person',
          payload: {'id': 'new-person', 'name': 'Локальный'},
        ),
      );
      await db.bindAccountOwner('new');
      final view = await db.readPeople(demoGroup);
      expect(view.people, isEmpty);
      expect(view.participations, isEmpty);
      expect(view.commands, isEmpty);
      expect(view.ready, isFalse);
    },
  );
  test(
    'a person still visible through another trip keeps the pending card edit',
    () async {
      final db = open();
      await db.cacheCatalog(_catalog());
      await db.cacheRoster(_roster());
      await db.queuePeople(
        const PeopleCommand(
          id: 'edit-person',
          teamId: demoTeam,
          kind: 'save_person',
          payload: {'id': 'person', 'name': 'Уточнённое имя'},
          expectedVersion: 1,
        ),
      );
      await db.cacheCatalog(
        TripCatalog(
          teams: _catalog().teams,
          routes: _catalog().routes,
          trips: [serverTrip('another-trip', draft())],
        ),
        accessiblePeople: {'person'},
      );
      expect(await db.serverRoster(demoGroup), isNull);
      expect((await db.peopleCommands()).single.id, 'edit-person');
      expect((await db.readPeople(null)).people.single.name, 'Уточнённое имя');
    },
  );

  test(
    'an old rejection only becomes a new application by explicit action',
    () async {
      createV1Fixture(File('${directory.path}/client.sqlite'));
      final db = open();
      final old = (await db.pendingCommands(demoGroup)).single;
      await db.reject(old, 'capacity_reached');
      await db.cacheCatalog(_catalog());
      final controller = Stage1Controller(
        db,
        _StageApi(),
        peopleApi: _PeopleApi(),
        retryInterval: null,
      );
      addTearDown(controller.close);
      await controller.initialize(autoSync: false);
      controller.setOffline(true);
      expect(controller.peopleView.commands, isEmpty);
      await controller.retryLegacyRegistration(
        controller.peopleView.participations.single,
      );
      expect(controller.peopleView.commands, hasLength(2));
      expect(controller.peopleView.bookings, hasLength(1));
      final p = controller.peopleView.participations.single;
      expect(p.id, old.registrationId);
      expect(p.status, 'application');
      expect(p.pending, isTrue);
      expect(p.data['legacy_rejection'], isNull);
      expect(await db.pendingCommands(demoGroup), isEmpty);
    },
  );
}

class _StageApi implements Stage1Api {
  bool visible = true;
  @override
  Future<void> prepare() async {}
  @override
  Future<TripCatalog> catalog() async => _catalog(visible: visible);
  @override
  Future<TripRoute> createRoute(RouteCommand command) =>
      throw UnimplementedError();
  @override
  Future<TripSaveResult> saveTrip(TripCommand command) =>
      throw UnimplementedError();
  @override
  PrototypeApi groupApi(String tripId) => _EmptyLegacy();
}

class _EmptyLegacy implements PrototypeApi {
  @override
  String get groupId => demoGroup;
  @override
  Future<void> prepare() async {}
  @override
  Future<RegistrationResult> submit(RegistrationCommand command) =>
      throw UnimplementedError();
  @override
  Future<GroupPage> pull(int after) async => GroupPage(
    group: PrototypeGroup(
      id: demoGroup,
      title: 'Выезд',
      route: 'Река',
      startsAt: draft().startsAt,
      capacity: 5,
    ),
    changes: [],
    cursor: after,
    hasMore: false,
  );
}

class _PeopleApi implements PeopleApi {
  bool visible = true;
  int submissions = 0;
  @override
  Future<JsonMap> catalog() async => {
    'teams': [
      {'id': demoTeam, 'revision': 10},
    ],
    'people': visible ? [_person] : [],
  };
  @override
  Future<JsonMap> roster(String tripId, int revision) async => _roster();
  @override
  Future<JsonMap> submit(PeopleCommand command) async {
    submissions++;
    throw const GroupAccessDenied();
  }
}
