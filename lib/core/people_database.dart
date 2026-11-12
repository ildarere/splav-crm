import 'dart:convert';
import 'package:drift/drift.dart';
import 'prototype_database.dart';
import 'people_models.dart';

Future<void> createPeopleSchema(PrototypeDatabase db) async {
  await db.customStatement(
    'CREATE TABLE person_cards(id TEXT PRIMARY KEY NOT NULL, data TEXT NOT NULL)',
  );
  await db.customStatement(
    'CREATE TABLE roster_cache(trip_id TEXT PRIMARY KEY NOT NULL,data TEXT NOT NULL)',
  );
  await db.customStatement(
    '''CREATE TABLE people_outbox(sequence INTEGER PRIMARY KEY,
    operation_id TEXT UNIQUE NOT NULL,team_id TEXT NOT NULL,trip_id TEXT,data TEXT NOT NULL)''',
  );
}

extension PeopleDatabase on PrototypeDatabase {
  Future<List<PeopleCommand>> peopleCommands() async =>
      (await customSelect(
            'SELECT data FROM people_outbox ORDER BY sequence',
          ).get())
          .map(
            (row) => PeopleCommand.fromJson(
              jsonDecode(row.read<String>('data')) as JsonMap,
            ),
          )
          .toList();

  Future<void> queuePeople(PeopleCommand command) => customStatement(
    'INSERT INTO people_outbox(operation_id,team_id,trip_id,data) VALUES (?,?,?,?)',
    [command.id, command.teamId, command.tripId, jsonEncode(command.toJson())],
  );

  Future<void> recordPeopleResult(PeopleCommand command, JsonMap result) async {
    await customStatement(
      'UPDATE people_outbox SET data=? WHERE operation_id=?',
      [
        jsonEncode({
          ...command.toJson(),
          'ack_revision': result['revision'],
          'error': result['reason'],
        }),
        command.id,
      ],
    );
  }

  Future<void> cachePeople(JsonMap catalog) => transaction(() async {
    final people = (catalog['people'] as List).cast<JsonMap>();
    final ids = people.map((p) => p['id']).toSet();
    final teams = {
      for (final t in catalog['teams'] as List)
        t['id'] as String: t['revision'] as int,
    };
    final encoded = jsonEncode(people);
    await customStatement(
      'DELETE FROM person_cards WHERE id NOT IN (SELECT json_extract(value,\'\$.id\') FROM json_each(?))',
      [encoded],
    );
    await customStatement(
      '''INSERT INTO person_cards(id,data)
      SELECT json_extract(value,'\$.id'),json(value) FROM json_each(?) WHERE 1
      ON CONFLICT(id) DO UPDATE SET data=excluded.data WHERE person_cards.data<>excluded.data''',
      [encoded],
    );
    for (final command in await peopleCommands()) {
      if (!teams.containsKey(command.teamId)) {
        await discardPeople(command.id);
      } else if (command.tripId == null) {
        final lost =
            command.expectedVersion > 0 &&
            command.kind != 'merge_people' &&
            !ids.contains(command.payload['id']);
        if (lost) {
          await discardPeople(command.id);
        } else if (command.ackRevision != null &&
            teams[command.teamId]! >= command.ackRevision!) {
          await customStatement(
            'DELETE FROM people_outbox WHERE operation_id=?',
            [command.id],
          );
        }
      }
    }
  });

  Future<int> rosterRevision(String tripId) async {
    final row = await customSelect(
      'SELECT data FROM roster_cache WHERE trip_id=?',
      variables: [Variable(tripId)],
    ).getSingleOrNull();
    return row == null
        ? -1
        : (jsonDecode(row.read<String>('data'))['revision'] as int);
  }

  Future<void> cacheRoster(JsonMap snapshot) => transaction(() async {
    final tripId = snapshot['trip_id'] as String;
    if (snapshot['unchanged'] != true) {
      await customStatement(
        'INSERT OR REPLACE INTO roster_cache(trip_id,data) VALUES (?,?)',
        [
          tripId,
          jsonEncode({
            ...snapshot,
            'cached_at': DateTime.now().toUtc().toIso8601String(),
          }),
        ],
      );
      for (final person in snapshot['people'] as List? ?? []) {
        await customStatement(
          'INSERT OR REPLACE INTO person_cards(id,data) VALUES (?,?)',
          [person['id'], jsonEncode(person)],
        );
      }
    } else {
      final current = await serverRoster(tripId);
      if (current == null) {
        throw StateError('Получен курсор без локального снимка.');
      }
      await customStatement('UPDATE roster_cache SET data=? WHERE trip_id=?', [
        jsonEncode({
          ...current,
          'cached_at': DateTime.now().toUtc().toIso8601String(),
        }),
        tripId,
      ]);
    }
    for (final command in await peopleCommands()) {
      if (command.tripId == tripId &&
          command.ackRevision != null &&
          command.ackRevision! <= (snapshot['revision'] as int)) {
        await customStatement(
          'DELETE FROM people_outbox WHERE operation_id=?',
          [command.id],
        );
      }
    }
  });

  Future<void> discardPeople(String id) => transaction(() async {
    final removed = {id};
    for (final command in await peopleCommands()) {
      if (removed.contains(command.id) ||
          command.dependencies.any(removed.contains)) {
        removed.add(command.id);
        await customStatement(
          'DELETE FROM people_outbox WHERE operation_id=?',
          [command.id],
        );
      }
    }
  });

  Future<PeopleCommand?> nextPeopleCommand() async {
    final commands = await peopleCommands();
    final ids = commands.map((c) => c.id).toSet();
    return commands
        .where(
          (c) =>
              c.error == null &&
              c.ackRevision == null &&
              !c.dependencies.any(ids.contains),
        )
        .firstOrNull;
  }

  Future<JsonMap?> serverPerson(String id) async {
    final row = await customSelect(
      'SELECT data FROM person_cards WHERE id=?',
      variables: [Variable(id)],
    ).getSingleOrNull();
    return row == null ? null : jsonDecode(row.read<String>('data')) as JsonMap;
  }

  Future<JsonMap?> serverRoster(String tripId) async {
    final row = await customSelect(
      'SELECT data FROM roster_cache WHERE trip_id=?',
      variables: [Variable(tripId)],
    ).getSingleOrNull();
    return row == null ? null : jsonDecode(row.read<String>('data')) as JsonMap;
  }

  // Project version 2 data without changing its queue or inventing server IDs.
  // The first authoritative roster replaces this read-only projection.
  Future<List<JsonMap>> _legacyParticipants(String? tripId) async {
    final rows = await customSelect(
      '''SELECT r.*,p.name,c.server_json FROM registrations r
      JOIN people p ON p.id=r.person_id JOIN trip_catalog c ON c.id=r.group_id
      WHERE (? IS NULL OR r.group_id=?)''',
      variables: [Variable<String>(tripId), Variable<String>(tripId)],
    ).get();
    return rows
        .map(
          (r) => {
            'id': r.read<String>('id'),
            'person_id': r.read<String>('person_id'),
            'name': r.read<String>('name'),
            'legacy_status': r.read<String>('status'),
            'reason': r.readNullable<String>('reason'),
            'trip': jsonDecode(r.read<String>('server_json')) as JsonMap,
          },
        )
        .toList();
  }

  Future<void> prunePeopleToAccess({Set<String> candidates = const {}}) async {
    final roles = {
      for (final r in await customSelect('SELECT * FROM workspace_teams').get())
        r.read<String>('id'): r.read<String>('role'),
    };
    await customStatement(
      '''CREATE TABLE IF NOT EXISTS account_identity (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),user_id TEXT NOT NULL)''',
    );
    final identity = await customSelect(
      'SELECT user_id FROM account_identity',
    ).getSingleOrNull();
    final owner = identity?.read<String>('user_id');
    final referenced = <String>{};
    for (final row in await customSelect(
      'SELECT data FROM roster_cache',
    ).get()) {
      final roster = jsonDecode(row.read<String>('data')) as JsonMap;
      for (final p in roster['participations'] as List) {
        referenced.add(p['person_id'] as String);
      }
      for (final b in roster['bookings'] as List) {
        if (b['contact_person_id'] is String) {
          referenced.add(b['contact_person_id'] as String);
        }
      }
    }
    for (final row in await customSelect(
      'SELECT id,data FROM person_cards',
    ).get()) {
      final p = jsonDecode(row.read<String>('data')) as JsonMap;
      if (roles.containsKey(p['team_id']) && !candidates.contains(p['id'])) {
        continue;
      }
      if (roles[p['team_id']] == 'admin' ||
          (roles.containsKey(p['team_id']) &&
              owner != null &&
              p['created_by'] == owner) ||
          (roles.containsKey(p['team_id']) && referenced.contains(p['id']))) {
        continue;
      }
      await customStatement('DELETE FROM person_cards WHERE id=?', [p['id']]);
      for (final c in await peopleCommands()) {
        if (c.expectedVersion > 0 &&
            c.tripId == null &&
            c.personIds.contains(p['id'])) {
          await discardPeople(c.id);
        }
      }
    }
    for (final c in await peopleCommands()) {
      if (!roles.containsKey(c.teamId)) await discardPeople(c.id);
    }
  }

  Future<PeopleView> readPeople(String? tripId) => transaction(() async {
    final people = {
      for (final row in await customSelect(
        'SELECT data FROM person_cards',
      ).get())
        (jsonDecode(row.read<String>('data')) as JsonMap)['id'] as String:
            PersonCard(jsonDecode(row.read<String>('data')) as JsonMap),
    };
    final legacyPeople = await _legacyParticipants(null);
    final authoritative = (await customSelect(
      'SELECT trip_id FROM roster_cache',
    ).get()).map((r) => r.read<String>('trip_id')).toSet();
    for (final p in legacyPeople.where(
      (p) =>
          p['legacy_status'] != 'confirmed' ||
          !authoritative.contains(p['trip']['id']),
    )) {
      people.putIfAbsent(
        p['person_id'] as String,
        () => PersonCard({
          'id': p['person_id'],
          'team_id': p['trip']['team_id'],
          'name': p['name'],
          'version': 0,
          'legacy': true,
        }, pending: p['legacy_status'] == 'pending'),
      );
    }
    final row = tripId == null
        ? null
        : await customSelect(
            'SELECT data FROM roster_cache WHERE trip_id=?',
            variables: [Variable(tripId)],
          ).getSingleOrNull();
    var roster = row == null
        ? null
        : jsonDecode(row.read<String>('data')) as JsonMap;
    if (roster == null && tripId != null) {
      final cached = await customSelect(
        'SELECT offline_ready FROM trip_catalog WHERE id=?',
        variables: [Variable(tripId)],
      ).getSingleOrNull();
      if (cached?.read<int>('offline_ready') == 1) {
        roster = {'bookings': <JsonMap>[], 'participations': <JsonMap>[]};
      }
    }
    final bookings = {
      for (final item in roster?['bookings'] as List? ?? [])
        item['id'] as String: Booking(Map<String, dynamic>.from(item as Map)),
    };
    final participations = {
      for (final item in roster?['participations'] as List? ?? [])
        item['id'] as String: Participation(
          Map<String, dynamic>.from(item as Map),
        ),
    };
    for (final p in legacyPeople.where((p) => p['trip']['id'] == tripId)) {
      if (participations.containsKey(p['id']) ||
          (row != null && p['legacy_status'] == 'confirmed')) {
        continue;
      }
      final id = p['id'] as String, bookingId = 'legacy-${p['id']}';
      bookings[bookingId] = Booking({
        'id': bookingId,
        'trip_id': tripId,
        'contact_name': p['name'],
        'legacy': true,
      });
      participations[id] = Participation(
        {
          'id': id,
          'trip_id': tripId,
          'booking_id': bookingId,
          'person_id': p['person_id'],
          'status': p['legacy_status'] == 'confirmed'
              ? 'confirmed'
              : 'application',
          'legacy': true,
          'legacy_rejection': p['legacy_status'] == 'rejected',
          'reason': p['reason'],
          'version': 0,
          'agreed_price_kopeks': p['trip']['base_price_kopeks'],
        },
        pending: p['legacy_status'] == 'pending',
        conflict: p['legacy_status'] == 'rejected',
      );
    }
    final confirmed = participations.values
        .where((p) => p.status == 'confirmed' && p.role == 'client')
        .length;
    final instructors = participations.values
        .where((p) => p.status == 'confirmed' && p.role == 'instructor')
        .length;
    final commands = await peopleCommands();
    final selectedMetadata = tripId == null
        ? null
        : await customSelect(
            'SELECT server_json FROM trip_catalog WHERE id=?',
            variables: [Variable(tripId)],
          ).getSingleOrNull();
    final basePrice = selectedMetadata == null
        ? 0
        : (jsonDecode(selectedMetadata.read<String>('server_json'))
                  as JsonMap)['base_price_kopeks']
              as int;
    for (final command in commands) {
      final payload = command.payload;
      final conflict = command.error != null;
      if (command.kind == 'save_person') {
        final id = payload['id'] as String;
        people[id] = PersonCard(
          {
            ...?people[id]?.data,
            ...payload,
            'team_id': command.teamId,
            'version': command.expectedVersion + 1,
          },
          pending: true,
          conflict: conflict,
        );
      } else if (command.kind == 'merge_people') {
        final source = people[payload['id']];
        if (source != null) {
          people[source.id] = PersonCard(
            {
              ...source.data,
              'archived': true,
              'merged_into': payload['target_id'],
            },
            pending: true,
            conflict: conflict,
          );
        }
      }
      if (command.tripId != tripId) continue;
      if (command.kind == 'save_booking') {
        final id = payload['id'] as String;
        bookings[id] = Booking(
          {
            ...payload,
            'trip_id': tripId,
            'version': command.expectedVersion + 1,
          },
          pending: true,
          conflict: conflict,
        );
        for (final member in payload['members'] as List? ?? []) {
          participations[member['id'] as String] = Participation(
            {
              ...Map<String, dynamic>.from(member as Map),
              'trip_id': tripId,
              'booking_id': id,
              'status': 'confirmed',
              'agreed_price_kopeks': member['role'] == 'instructor'
                  ? 0
                  : basePrice,
              'version': 1,
            },
            pending: true,
            conflict: conflict,
          );
        }
      } else if (command.kind == 'set_status') {
        for (final id in (payload['ids'] as List).cast<String>()) {
          final p = participations[id];
          if (p != null) {
            final separate = conflict
                ? null
                : payload['separate_booking_id'] as String?;
            if (separate != null) {
              final person = people[p.personId];
              bookings[separate] = Booking({
                'id': separate,
                'trip_id': tripId,
                'contact_person_id': p.personId,
                'contact_name': person?.name ?? 'Участник',
                'phone': person?.phone ?? '',
                'version': 1,
              }, pending: true);
            }
            participations[id] = Participation(
              {
                ...p.data,
                'booking_id': ?separate,
                if (payload['status'] == 'waiting' && p.waitingAt == null)
                  'waiting_at': payload['requested_at'],
                'version': (payload['versions'][id] as int) + 1,
              },
              pending: true,
              conflict: conflict,
              requestedStatus:
                  conflict && payload['separate_booking_id'] != null
                  ? p.requestedStatus
                  : payload['status'] as String,
            );
          }
        }
      } else if (command.kind == 'move_participant') {
        final p = participations[payload['id']];
        if (p != null) {
          participations[p.id] = Participation(
            p.data,
            pending: true,
            conflict: conflict,
            requestedStatus: p.requestedStatus,
          );
        }
      } else if (command.kind == 'edit_participation') {
        final p = participations[payload['id']];
        if (p != null) {
          participations[p.id] = Participation(
            {...p.data, ...payload, 'version': command.expectedVersion + 1},
            pending: true,
            conflict: conflict,
            requestedStatus: p.requestedStatus,
          );
        }
      } else if (command.kind == 'set_prices') {
        for (final line in payload['lines'] as List) {
          final p = participations[line['id']];
          if (p != null) {
            participations[p.id] = Participation(
              {
                ...p.data,
                'agreed_price_kopeks': line['amount_kopeks'],
                'version': (line['version'] as int) + 1,
              },
              pending: true,
              conflict: conflict,
              requestedStatus: p.requestedStatus,
            );
          }
        }
      }
    }
    final sortedPeople = people.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final sortedParticipants = participations.values.toList()
      ..sort((a, b) {
        final at = a.waitingAt, bt = b.waitingAt;
        if (at != null && bt != null) {
          return at.compareTo(bt) != 0
              ? at.compareTo(bt)
              : a.id.compareTo(b.id);
        }
        if (at != null) return -1;
        if (bt != null) return 1;
        return a.id.compareTo(b.id);
      });
    return PeopleView(
      people: sortedPeople,
      bookings: bookings.values
          .where(
            (b) =>
                b.data['legacy'] != true ||
                participations.values.any((p) => p.bookingId == b.id),
          )
          .toList(),
      participations: sortedParticipants,
      commands: commands,
      ready: roster != null,
      confirmedCount: confirmed,
      instructorCount: instructors,
      syncedAt: DateTime.tryParse(roster?['cached_at'] as String? ?? ''),
    );
  });

  Future<List<JsonMap>> personHistory(String id) async {
    final history = <JsonMap>[];
    final rows = await customSelect(
      '''SELECT r.data,c.server_json FROM roster_cache r
      JOIN trip_catalog c ON c.id=r.trip_id''',
    ).get();
    for (final row in rows) {
      final roster = jsonDecode(row.read<String>('data')) as JsonMap;
      final trip = jsonDecode(row.read<String>('server_json')) as JsonMap;
      for (final p in roster['participations'] as List) {
        if (p['person_id'] == id) {
          history.add({
            ...Map<String, dynamic>.from(p as Map),
            'title': trip['title'],
            'starts_at': trip['starts_at'],
          });
        }
      }
    }
    history.sort(
      (a, b) => DateTime.parse(
        b['starts_at'] as String,
      ).compareTo(DateTime.parse(a['starts_at'] as String)),
    );
    return history;
  }
}
