import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/core/prototype.dart';
import 'stage1_fixture.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('splav-stage1-');
    final warning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(
      () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = warning,
    );
  });
  tearDown(() => directory.delete(recursive: true));

  Future<Stage1Controller> open(
    _Server api, {
    String file = 'client.sqlite',
  }) async {
    final controller = Stage1Controller(
      PrototypeDatabase(NativeDatabase(File('${directory.path}/$file'))),
      api,
      retryInterval: null,
    );
    addTearDown(controller.close);
    await controller.initialize(autoSync: false);
    return controller;
  }

  test('v1 migration retains old queue, group and cursor', () async {
    createV1Fixture(File('${directory.path}/client.sqlite'));
    final server = _Server()..trips[demoGroup] = serverTrip(demoGroup, draft());
    final controller = await open(server);
    expect(controller.trips.single.id, demoGroup);
    expect(controller.trips.single.isDownloaded, isTrue);
    expect(controller.trips.single.endsAt, DateTime.utc(2027, 5, 13, 6));
    expect(controller.trips.single.meetingAt, DateTime.utc(2027, 5, 12, 5, 30));
    expect(controller.pendingCommandCount, 1);
    expect(controller.selectedParticipants.single.name, 'Старая очередь');
    await controller.sync();
    expect(controller.pendingCommandCount, 0);
    expect(controller.selectedConfirmedCount, 1);
    expect(
      server.registrationCalls.single,
      '00000000-0000-4000-8000-000000000093',
    );
  });

  test(
    'an unfinished v1 download stays incomplete until its last page',
    () async {
      createV1Fixture(
        File('${directory.path}/client.sqlite'),
        lastSyncedAt: null,
      );
      final server = _Server()
        ..trips[demoGroup] = serverTrip(demoGroup, draft());
      final controller = await open(server);
      expect(controller.trips.single.downloadRequested, isTrue);
      expect(controller.trips.single.isDownloaded, isFalse);
      expect(controller.pendingCommandCount, 1);
      await controller.sync();
      expect(controller.trips.single.isDownloaded, isTrue);
      expect(controller.pendingCommandCount, 0);
    },
  );

  test(
    'two created trips, routes and downloaded rosters survive restart offline',
    () async {
      final server = _Server();
      var controller = await open(server);
      await controller.sync();
      controller.setOffline(true);
      await controller.createRoute('Новый маршрут', teamId: demoTeam);
      final route = controller.routes.singleWhere(
        (r) => r.name == 'Новый маршрут',
      );
      final first = await controller.saveTrip(
        draft(title: 'Первый', capacity: 4, routeId: route.id),
      );
      final second = await controller.saveTrip(
        draft(title: 'Второй', capacity: 8, startsAt: DateTime.utc(2027, 6, 1)),
      );
      expect(controller.pendingCommandCount, 3);
      await controller.close();
      controller = await open(server);
      expect(controller.trips, hasLength(2));
      expect(controller.pendingCommandCount, 3);
      await controller.sync();
      expect(controller.error, isNull);
      expect(controller.pendingCommandCount, 0);
      expect(controller.trips.every((t) => t.isDownloaded), isTrue);
      await controller.close();
      controller = await open(server);
      controller.setOffline(true);
      await controller.chooseTrip(first);
      expect(controller.selectedTrip?.title, 'Первый');
      expect(controller.selectedTrip?.capacity, 4);
      await controller.chooseTrip(second);
      expect(controller.selectedTrip?.capacity, 8);
      expect(controller.selectedTrip?.startsAt, DateTime.utc(2027, 6, 1));
    },
  );

  test(
    'accepted metadata command repeats same UUID after lost response',
    () async {
      final server = _Server()..dropNextSave = true;
      var controller = await open(server);
      await controller.sync();
      controller.setOffline(true);
      final id = await controller.saveTrip(draft());
      controller.setOffline(false);
      await controller.sync();
      expect(controller.pendingCommandCount, 1);
      expect(controller.error, isNotNull);
      await controller.close();
      controller = await open(server);
      await controller.sync();
      expect(controller.error, isNull);
      expect(controller.pendingCommandCount, 0);
      expect(server.saveCalls, [
        server.saveCalls.first,
        server.saveCalls.first,
      ]);
      expect(server.trips.keys, [id]);
    },
  );

  test(
    'stale metadata stays local until explicit reapply with current version',
    () async {
      final server = _Server()
        ..trips[demoGroup] = serverTrip(demoGroup, draft(title: 'Исходный'));
      final a = await open(server, file: 'a.sqlite');
      final b = await open(server, file: 'b.sqlite');
      await Future.wait([a.sync(), b.sync()]);
      a.setOffline(true);
      b.setOffline(true);
      await a.saveTrip(draft(title: 'Правка A'), tripId: demoGroup);
      await b.saveTrip(draft(title: 'Правка B'), tripId: demoGroup);
      a.setOffline(false);
      await a.sync();
      b.setOffline(false);
      await b.sync();
      expect(b.selectedTrip?.syncState, TripSyncState.conflict);
      expect(b.selectedTrip?.title, 'Правка B');
      expect(b.selectedTrip?.serverTrip?.title, 'Правка A');
      await b.retryConflict(demoGroup);
      await b.sync();
      expect(b.selectedTrip?.syncState, TripSyncState.synced);
      expect(server.trips[demoGroup]!['title'], 'Правка B');
    },
  );

  test(
    'revoked catalog removes downloaded people and queue before any push',
    () async {
      createV1Fixture(File('${directory.path}/client.sqlite'));
      final server = _Server();
      final controller = await open(server);
      expect(controller.pendingCommandCount, 1);
      await controller.sync();
      expect(controller.trips, isEmpty);
      expect(controller.selectedParticipants, isEmpty);
      expect(controller.pendingCommandCount, 0);
      expect(server.registrationCalls, isEmpty);
    },
  );

  test(
    'same-email account UUID change purges downloaded data and both queues',
    () async {
      createV1Fixture(File('${directory.path}/client.sqlite'));
      final server = _Server()
        ..trips[demoGroup] = serverTrip(demoGroup, draft());
      final controller = await open(server);
      await controller.database.bindAccountOwner('old-user-id');
      expect(controller.pendingCommandCount, 1);
      await controller.database.cacheCatalog(await server.catalog());
      await controller.initialize(autoSync: false);
      controller.setOffline(true);
      await controller.saveTrip(
        draft(title: 'Секретный локальный черновик'),
        tripId: demoGroup,
      );
      expect(controller.pendingCommandCount, 2);
      await controller.database.bindAccountOwner('new-user-id');
      final view = await controller.database.readWorkspace(demoGroup);
      expect(view.trips, isEmpty);
      expect(view.participants, isEmpty);
      expect(view.pendingCommandCount, 0);
    },
  );
}

class _Server implements Stage1Api {
  final trips = <String, Map<String, dynamic>>{};
  final routes = <TripRoute>[
    const TripRoute(id: demoRoute, teamId: demoTeam, name: 'Тестовый маршрут'),
  ];
  final changes = <String, List<RegistrationChange>>{};
  final receipts = <String, TripSaveResult>{};
  final saveCalls = <String>[];
  final registrationCalls = <String>[];
  bool dropNextSave = false;

  @override
  Future<void> prepare() async {}
  @override
  Future<TripCatalog> catalog() async => TripCatalog(
    teams: const [
      TripTeam(id: demoTeam, name: 'Тестовая команда', role: 'admin'),
    ],
    routes: List.of(routes),
    trips: trips.values.map((t) => Map<String, dynamic>.of(t)).toList(),
  );
  @override
  Future<TripRoute> createRoute(RouteCommand command) async {
    if (!routes.any((r) => r.id == command.route.id)) routes.add(command.route);
    return command.route;
  }

  @override
  PrototypeApi groupApi(String tripId) => _GroupApi(this, tripId);
  @override
  Future<TripSaveResult> saveTrip(TripCommand command) async {
    saveCalls.add(command.operationId);
    final result = receipts.putIfAbsent(command.operationId, () {
      final previous = trips[command.tripId];
      final version = previous?['metadata_version'] as int? ?? 0;
      if (command.expectedVersion != version) {
        return TripSaveResult(reason: 'version_conflict', current: previous);
      }
      final data = serverTrip(
        command.tripId,
        command.draft,
        version: version + 1,
      );
      trips[command.tripId] = data;
      return TripSaveResult(trip: data);
    });
    if (dropNextSave) {
      dropNextSave = false;
      throw TimeoutException('Saved but reply lost');
    }
    return result;
  }
}

class _GroupApi implements PrototypeApi {
  _GroupApi(this.server, this.groupId);
  final _Server server;
  @override
  final String groupId;
  @override
  Future<void> prepare() async {}
  @override
  Future<RegistrationResult> submit(RegistrationCommand command) async {
    server.registrationCalls.add(command.operationId);
    final feed = server.changes.putIfAbsent(groupId, () => []);
    if (!feed.any((e) => e.command.operationId == command.operationId)) {
      feed.add(RegistrationChange(revision: feed.length + 1, command: command));
    }
    return RegistrationResult.accepted(
      feed
          .firstWhere((e) => e.command.operationId == command.operationId)
          .revision,
    );
  }

  @override
  Future<GroupPage> pull(int after) async {
    final data = server.trips[groupId]!;
    final feed = server.changes[groupId] ?? [];
    return GroupPage(
      group: PrototypeGroup(
        id: groupId,
        title: data['title'] as String,
        route: data['route'] as String,
        startsAt: DateTime.parse(data['starts_at'] as String),
        capacity: data['capacity'] as int,
      ),
      changes: feed.where((c) => c.revision > after).toList(),
      cursor: feed.length,
      hasMore: false,
    );
  }
}
