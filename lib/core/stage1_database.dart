import 'dart:convert';
import 'package:drift/drift.dart';
import 'prototype_database.dart';
import 'stage1_models.dart';
import 'people_database.dart';

Future<void> createStage1Schema(PrototypeDatabase db) async {
  await db.customStatement('''CREATE TABLE workspace_teams (
    id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, role TEXT NOT NULL)''');
  await db.customStatement(
    '''CREATE TABLE trip_routes (
    id TEXT PRIMARY KEY NOT NULL, team_id TEXT NOT NULL, name TEXT NOT NULL)''',
  );
  await db.customStatement('''CREATE TABLE trip_catalog (
    id TEXT PRIMARY KEY NOT NULL, server_json TEXT NOT NULL,
    download_requested INTEGER NOT NULL DEFAULT 0,
    offline_ready INTEGER NOT NULL DEFAULT 0)''');
  await db.customStatement(
    '''CREATE TABLE trip_commands (
    sequence INTEGER PRIMARY KEY, operation_id TEXT UNIQUE NOT NULL,
    trip_id TEXT UNIQUE NOT NULL, expected_version INTEGER NOT NULL,
    payload TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',reason TEXT)''',
  );
  await db.customStatement('''CREATE TABLE route_commands (
    sequence INTEGER PRIMARY KEY, operation_id TEXT UNIQUE NOT NULL,
    route_id TEXT UNIQUE NOT NULL,team_id TEXT NOT NULL,name TEXT NOT NULL)''');
  final oldGroups = await db.customSelect('SELECT * FROM trip_groups').get();
  for (final row in oldGroups) {
    final starts = DateTime.parse(row.read<String>('starts_at'));
    final data = <String, dynamic>{
      'id': row.read<String>('id'),
      'team_id': '00000000-0000-4000-8000-000000000010',
      'route_id': '00000000-0000-4000-8000-000000000020',
      'title': row.read<String>('title'),
      'route': row.read<String>('route'),
      'starts_at': starts.toUtc().toIso8601String(),
      'ends_at': starts.add(const Duration(days: 1)).toUtc().toIso8601String(),
      'timezone': 'Europe/Saratov',
      'meeting_point': '',
      'meeting_at': starts
          .subtract(const Duration(minutes: 30))
          .toUtc()
          .toIso8601String(),
      'responsible_names': '',
      'capacity': row.read<int>('capacity'),
      'base_price_kopeks': 0,
      'notes': '',
      'status': 'open',
      'metadata_version': 1,
    };
    await db.customStatement(
      '''INSERT INTO trip_catalog
      (id,server_json,download_requested,offline_ready) VALUES (?,?,1,?)''',
      [
        data['id'],
        jsonEncode(data),
        row.readNullable<String>('last_synced_at') == null ? 0 : 1,
      ],
    );
  }
}

extension Stage1Database on PrototypeDatabase {
  Future<void> bindAccountOwner(String userId) => transaction(() async {
    if (userId.isEmpty) {
      throw ArgumentError('Идентификатор аккаунта обязателен.');
    }
    await customStatement(
      '''CREATE TABLE IF NOT EXISTS account_identity (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),user_id TEXT NOT NULL)''',
    );
    final existing = await customSelect(
      'SELECT user_id FROM account_identity WHERE singleton=1',
    ).getSingleOrNull();
    if (existing != null && existing.read<String>('user_id') != userId) {
      await clearAccountData();
    }
    await customStatement(
      'INSERT OR REPLACE INTO account_identity(singleton,user_id) VALUES (1,?)',
      [userId],
    );
  });

  Future<Stage1View> readWorkspace(String? selectedId) => transaction(() async {
    final teamRows = await customSelect(
      'SELECT * FROM workspace_teams ORDER BY name',
    ).get();
    final routeRows = await customSelect(
      'SELECT * FROM trip_routes ORDER BY name',
    ).get();
    final commandRows = await customSelect(
      'SELECT * FROM trip_commands ORDER BY sequence',
    ).get();
    final catalogRows = await customSelect(
      '''SELECT c.*,g.last_synced_at FROM trip_catalog c
      LEFT JOIN trip_groups g ON g.id=c.id''',
    ).get();
    final commands = {
      for (final row in commandRows) row.read<String>('trip_id'): row,
    };
    final trips = <Trip>[];
    for (final row in catalogRows) {
      final server =
          jsonDecode(row.read<String>('server_json')) as Map<String, dynamic>;
      final command = commands[row.read<String>('id')];
      final syncedAt = row.readNullable<String>('last_synced_at');
      final downloaded = row.read<int>('offline_ready') == 1;
      final requested = row.read<int>('download_requested') == 1;
      Trip convert(
        Map<String, dynamic> data, {
        TripSyncState state = TripSyncState.synced,
        String? reason,
        Trip? current,
      }) => Trip(
        id: data['id'] as String,
        route: data['route'] as String? ?? '',
        version: data['metadata_version'] as int,
        isDownloaded: downloaded,
        downloadRequested: requested,
        syncState: state,
        conflictReason: reason,
        serverTrip: current,
        lastSyncedAt: syncedAt == null ? null : DateTime.parse(syncedAt),
        bookedClients: data['booked_clients'] as int? ?? 0,
        confirmedClients: data['confirmed_clients'] as int? ?? 0,
        waitingClients: data['waiting_clients'] as int? ?? 0,
        instructors: data['instructors'] as int? ?? 0,
        importMetadata: Map<String, dynamic>.from(
          data['import_metadata'] as Map? ?? {},
        ),
        draft: TripDraft.fromJson(data, data['team_id'] as String),
      );
      if (command == null) {
        trips.add(convert(server));
      } else {
        final payload =
            jsonDecode(command.read<String>('payload')) as Map<String, dynamic>;
        final local = {...server, ...payload};
        final routeId = payload['route_id'];
        for (final route in routeRows) {
          if (route.read<String>('id') == routeId) {
            local['route'] = route.read<String>('name');
          }
        }
        trips.add(
          convert(
            local,
            state: command.read<String>('status') == 'pending'
                ? TripSyncState.pending
                : TripSyncState.conflict,
            reason: command.readNullable<String>('reason'),
            current: convert(server),
          ),
        );
      }
    }
    trips.sort((a, b) => a.startsAt.compareTo(b.startsAt));
    final pendingRoutes = await customSelect(
      'SELECT count(*) AS n FROM route_commands',
    ).getSingle();
    final pendingRegistrations = await customSelect(
      'SELECT count(*) AS n FROM outbox',
    ).getSingle();
    return Stage1View(
      teams: teamRows
          .map(
            (r) => TripTeam(
              id: r.read<String>('id'),
              name: r.read<String>('name'),
              role: r.read<String>('role'),
            ),
          )
          .toList(),
      routes: routeRows
          .map(
            (r) => TripRoute(
              id: r.read<String>('id'),
              teamId: r.read<String>('team_id'),
              name: r.read<String>('name'),
            ),
          )
          .toList(),
      trips: trips,
      participants: selectedId == null
          ? []
          : (await readGroup(selectedId)).participants,
      pendingCommandCount:
          commandRows.length +
          pendingRoutes.read<int>('n') +
          pendingRegistrations.read<int>('n'),
    );
  });

  Future<void> cacheCatalog(
    TripCatalog catalog, {
    Set<String> accessiblePeople = const {},
  }) => transaction(() async {
    final ids = catalog.trips.map((t) => t['id'] as String).toSet();
    final teamIds = catalog.teams.map((t) => t.id).toSet();
    final local = await customSelect(
      '''SELECT c.id,c.server_json,q.expected_version FROM trip_catalog c
      LEFT JOIN trip_commands q ON q.trip_id=c.id''',
    ).get();
    for (final row in local) {
      if (ids.contains(row.read<String>('id'))) continue;
      final data =
          jsonDecode(row.read<String>('server_json')) as Map<String, dynamic>;
      final isLocalCreate = row.readNullable<int>('expected_version') == 0;
      if (isLocalCreate && teamIds.contains(data['team_id'])) continue;
      await deleteTripCache(
        row.read<String>('id'),
        accessiblePeople: accessiblePeople,
      );
    }
    await customStatement('DELETE FROM workspace_teams');
    for (final team in catalog.teams) {
      await customStatement('INSERT INTO workspace_teams VALUES (?,?,?)', [
        team.id,
        team.name,
        team.role,
      ]);
    }
    await customStatement('DELETE FROM trip_routes');
    for (final route in catalog.routes) {
      await customStatement('INSERT INTO trip_routes VALUES (?,?,?)', [
        route.id,
        route.teamId,
        route.name,
      ]);
    }
    final pendingRoutes = await customSelect(
      'SELECT * FROM route_commands',
    ).get();
    for (final row in pendingRoutes) {
      if (!teamIds.contains(row.read<String>('team_id'))) {
        await customStatement('DELETE FROM route_commands WHERE route_id=?', [
          row.read<String>('route_id'),
        ]);
        continue;
      }
      await customStatement(
        'INSERT OR IGNORE INTO trip_routes VALUES (?,?,?)',
        [
          row.read<String>('route_id'),
          row.read<String>('team_id'),
          row.read<String>('name'),
        ],
      );
    }
    for (final trip in catalog.trips) {
      await cacheTrip(trip);
    }
    await prunePeopleToAccess();
  });

  Future<void> cacheTrip(Map<String, dynamic> trip) async {
    await customStatement(
      '''INSERT INTO trip_catalog(id,server_json) VALUES (?,?)
      ON CONFLICT(id) DO UPDATE SET server_json=excluded.server_json''',
      [trip['id'], jsonEncode(trip)],
    );
    await customStatement(
      '''INSERT INTO trip_groups(id,title,route,starts_at,capacity,cursor)
      VALUES (?,?,?,?,?,0) ON CONFLICT(id) DO UPDATE SET title=excluded.title,
        route=excluded.route,starts_at=excluded.starts_at,capacity=excluded.capacity''',
      [
        trip['id'],
        trip['title'],
        trip['route'] ?? '',
        trip['starts_at'],
        trip['capacity'],
      ],
    );
  }

  Future<void> queueTrip(TripCommand command) => transaction(() async {
    final previous = await customSelect(
      'SELECT 1 FROM trip_commands WHERE trip_id=?',
      variables: [Variable(command.tripId)],
    ).getSingleOrNull();
    if (previous != null) {
      throw StateError(
        'Сначала синхронизируйте или разберите предыдущую правку выезда.',
      );
    }
    if (command.expectedVersion == 0) {
      final route = await customSelect(
        'SELECT name FROM trip_routes WHERE id=?',
        variables: [Variable(command.draft.routeId)],
      ).getSingle();
      await cacheTrip({
        'id': command.tripId,
        'team_id': command.draft.teamId,
        'metadata_version': 0,
        'route': route.read<String>('name'),
        ...command.draft.toJson(),
      });
      await customStatement(
        'UPDATE trip_catalog SET download_requested=1 WHERE id=?',
        [command.tripId],
      );
    }
    await customStatement(
      '''INSERT INTO trip_commands(operation_id,trip_id,expected_version,payload)
      VALUES (?,?,?,?)''',
      [
        command.operationId,
        command.tripId,
        command.expectedVersion,
        jsonEncode(command.draft.toJson()),
      ],
    );
  });

  Future<List<TripCommand>> tripCommands() async {
    final rows = await customSelect(
      '''SELECT q.*,c.server_json FROM trip_commands q JOIN trip_catalog c
      ON c.id=q.trip_id WHERE q.status='pending' ORDER BY q.sequence''',
    ).get();
    return rows
        .map(
          (r) => TripCommand(
            operationId: r.read<String>('operation_id'),
            tripId: r.read<String>('trip_id'),
            expectedVersion: r.read<int>('expected_version'),
            draft: TripDraft.fromJson(
              jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
              (jsonDecode(r.read<String>('server_json'))
                      as Map<String, dynamic>)['team_id']
                  as String,
            ),
          ),
        )
        .toList();
  }

  Future<void> applyTripResult(
    TripCommand command,
    TripSaveResult result,
  ) => transaction(() async {
    if (result.trip case final trip?) {
      await cacheTrip(trip);
      await customStatement('DELETE FROM trip_commands WHERE operation_id=?', [
        command.operationId,
      ]);
    } else {
      if (result.current case final current?) await cacheTrip(current);
      await customStatement(
        "UPDATE trip_commands SET status='conflict',reason=? WHERE operation_id=?",
        [result.reason ?? 'unknown', command.operationId],
      );
    }
  });

  Future<void> discardTripCommand(String tripId) => transaction(() async {
    final row = await customSelect(
      'SELECT expected_version FROM trip_commands WHERE trip_id=?',
      variables: [Variable(tripId)],
    ).getSingleOrNull();
    if (row?.read<int>('expected_version') == 0) {
      await deleteTripCache(tripId);
    } else {
      await customStatement('DELETE FROM trip_commands WHERE trip_id=?', [
        tripId,
      ]);
    }
  });

  Future<void> queueRoute(RouteCommand command) => transaction(() async {
    await customStatement('INSERT INTO trip_routes VALUES (?,?,?)', [
      command.route.id,
      command.route.teamId,
      command.route.name,
    ]);
    await customStatement(
      'INSERT INTO route_commands(operation_id,route_id,team_id,name) VALUES (?,?,?,?)',
      [
        command.operationId,
        command.route.id,
        command.route.teamId,
        command.route.name,
      ],
    );
  });

  Future<List<RouteCommand>> routeCommands() async {
    final rows = await customSelect(
      'SELECT * FROM route_commands ORDER BY sequence',
    ).get();
    return rows
        .map(
          (r) => RouteCommand(
            operationId: r.read<String>('operation_id'),
            route: TripRoute(
              id: r.read<String>('route_id'),
              teamId: r.read<String>('team_id'),
              name: r.read<String>('name'),
            ),
          ),
        )
        .toList();
  }

  Future<void> applyRouteResult(RouteCommand command, TripRoute route) =>
      transaction(() async {
        await customStatement(
          'DELETE FROM route_commands WHERE operation_id=?',
          [command.operationId],
        );
        await customStatement(
          'INSERT OR REPLACE INTO trip_routes VALUES (?,?,?)',
          [route.id, route.teamId, route.name],
        );
      });

  Future<void> rejectRoute(
    RouteCommand command,
    String reason,
  ) => transaction(() async {
    await customStatement('DELETE FROM route_commands WHERE operation_id=?', [
      command.operationId,
    ]);
    await customStatement('DELETE FROM trip_routes WHERE id=?', [
      command.route.id,
    ]);
    final rows = await customSelect(
      'SELECT trip_id,payload FROM trip_commands',
    ).get();
    for (final row in rows) {
      final payload =
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
      if (payload['route_id'] == command.route.id) {
        await customStatement(
          "UPDATE trip_commands SET status='conflict',reason=? WHERE trip_id=?",
          [reason, row.read<String>('trip_id')],
        );
      }
    }
  });

  Future<void> requestDownload(
    String tripId,
    bool value,
  ) => transaction(() async {
    if (!value) {
      final queue = await pendingCommands(tripId);
      final tripQueue = await customSelect(
        'SELECT 1 FROM trip_commands WHERE trip_id=?',
        variables: [Variable(tripId)],
      ).getSingleOrNull();
      final rosterQueue = (await peopleCommands()).any(
        (c) => c.tripId == tripId,
      );
      if (queue.isNotEmpty || tripQueue != null || rosterQueue) {
        throw StateError(
          'Сначала синхронизируйте или разберите изменения этого выезда.',
        );
      }
      await forgetGroup(tripId);
      await customStatement('DELETE FROM roster_cache WHERE trip_id=?', [
        tripId,
      ]);
      await customStatement(
        'UPDATE trip_catalog SET download_requested=0,offline_ready=0 WHERE id=?',
        [tripId],
      );
    } else {
      final row = await customSelect(
        'SELECT server_json FROM trip_catalog WHERE id=?',
        variables: [Variable(tripId)],
      ).getSingle();
      await cacheTrip(
        jsonDecode(row.read<String>('server_json')) as Map<String, dynamic>,
      );
      await customStatement(
        'UPDATE trip_catalog SET download_requested=1 WHERE id=?',
        [tripId],
      );
    }
  });

  Future<List<String>> requestedTripIds() async => (await customSelect(
    'SELECT id FROM trip_catalog WHERE download_requested=1',
  ).get()).map((r) => r.read<String>('id')).toList();

  Future<void> markDownloaded(String id) => customStatement(
    'UPDATE trip_catalog SET offline_ready=1 WHERE id=?',
    [id],
  );

  Future<void> deleteTripCache(
    String id, {
    Set<String> accessiblePeople = const {},
  }) => transaction(() async {
    final oldRoster = await serverRoster(id);
    final candidates = <String>{
      for (final p in oldRoster?['people'] as List? ?? []) p['id'] as String,
    };
    for (final command in await peopleCommands()) {
      if (command.tripId == id || command.originTripId == id) {
        await discardPeople(command.id);
      }
    }
    await customStatement('DELETE FROM roster_cache WHERE trip_id=?', [id]);
    await customStatement('DELETE FROM trip_commands WHERE trip_id=?', [id]);
    await forgetGroup(id);
    await customStatement('DELETE FROM trip_catalog WHERE id=?', [id]);
    await prunePeopleToAccess(
      candidates: candidates.difference(accessiblePeople),
    );
  });

  Future<void> clearAccountData() => transaction(() async {
    await customStatement(
      '''CREATE TABLE IF NOT EXISTS account_identity (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),user_id TEXT NOT NULL)''',
    );
    for (final table in [
      'people_outbox',
      'roster_cache',
      'person_cards',
      'outbox',
      'registrations',
      'people',
      'trip_groups',
      'trip_commands',
      'trip_catalog',
      'route_commands',
      'trip_routes',
      'workspace_teams',
      'account_identity',
    ]) {
      await customStatement('DELETE FROM $table');
    }
  });
}
