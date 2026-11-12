import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import 'local_storage_native.dart'
    if (dart.library.js_interop) 'local_storage_web.dart';
import 'prototype_models.dart';
import 'stage1_database.dart';
import 'people_database.dart';

/// The prototype uses a small SQL schema directly through Drift.
class PrototypeDatabase extends GeneratedDatabase {
  PrototypeDatabase(super.executor);

  static Future<PrototypeDatabase> open({required String scope}) async {
    final key = sha256.convert(utf8.encode(scope)).toString();
    return PrototypeDatabase(await openLocalStorage(key));
  }

  @override
  int get schemaVersion => 3;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement('''
        CREATE TABLE trip_groups (
          id TEXT PRIMARY KEY NOT NULL,
          title TEXT NOT NULL,
          route TEXT NOT NULL,
          starts_at TEXT NOT NULL,
          capacity INTEGER NOT NULL CHECK (capacity >= 0),
          cursor INTEGER NOT NULL CHECK (cursor >= 0),
          last_synced_at TEXT
        )
      ''');
      await customStatement('''
        CREATE TABLE people (
          id TEXT PRIMARY KEY NOT NULL,
          name TEXT NOT NULL
        )
      ''');
      await customStatement('''
        CREATE TABLE registrations (
          id TEXT PRIMARY KEY NOT NULL,
          group_id TEXT NOT NULL REFERENCES trip_groups(id),
          person_id TEXT NOT NULL REFERENCES people(id),
          status TEXT NOT NULL CHECK (status IN ('pending', 'confirmed', 'rejected')),
          reason TEXT,
          UNIQUE (group_id, person_id)
        )
      ''');
      await customStatement('''
        CREATE TABLE outbox (
          sequence INTEGER PRIMARY KEY,
          operation_id TEXT UNIQUE NOT NULL,
          registration_id TEXT UNIQUE NOT NULL REFERENCES registrations(id)
        )
      ''');
      await createStage1Schema(this);
      await createPeopleSchema(this);
    },
    onUpgrade: (_, from, to) async {
      if (from < 2) await createStage1Schema(this);
      if (from < 3) await createPeopleSchema(this);
    },
    beforeOpen: (_) => customStatement('PRAGMA foreign_keys = ON'),
  );

  Future<LocalGroupView> readGroup(String groupId) => transaction(() async {
    final row = await customSelect(
      'SELECT * FROM trip_groups WHERE id = ?',
      variables: [Variable(groupId)],
    ).getSingleOrNull();
    if (row == null) return const LocalGroupView();

    final participants = await customSelect(
      '''
      SELECT r.id, p.name, r.status, r.reason
      FROM registrations r JOIN people p ON p.id = r.person_id
      WHERE r.group_id = ?
      ORDER BY CASE r.status WHEN 'confirmed' THEN 0 WHEN 'pending' THEN 1 ELSE 2 END,
        p.name, r.id
    ''',
      variables: [Variable(groupId)],
    ).get();
    final syncedAt = row.readNullable<String>('last_synced_at');
    return LocalGroupView(
      group: PrototypeGroup(
        id: row.read<String>('id'),
        title: row.read<String>('title'),
        route: row.read<String>('route'),
        startsAt: DateTime.parse(row.read<String>('starts_at')),
        capacity: row.read<int>('capacity'),
      ),
      cursor: row.read<int>('cursor'),
      lastSyncedAt: syncedAt == null ? null : DateTime.parse(syncedAt),
      participants: List.unmodifiable(
        participants.map((participant) {
          return PrototypeParticipant(
            id: participant.read<String>('id'),
            name: participant.read<String>('name'),
            status: ParticipantStatus.values.byName(
              participant.read<String>('status'),
            ),
            reason: participant.readNullable<String>('reason'),
          );
        }),
      ),
    );
  });

  Future<void> enqueue(RegistrationCommand command) => transaction(() async {
    await customStatement('INSERT INTO people (id, name) VALUES (?, ?)', [
      command.personId,
      command.name,
    ]);
    await customStatement(
      '''
      INSERT INTO registrations (id, group_id, person_id, status)
      VALUES (?, ?, ?, 'pending')
    ''',
      [command.registrationId, command.groupId, command.personId],
    );
    await customStatement(
      '''
      INSERT INTO outbox (operation_id, registration_id) VALUES (?, ?)
    ''',
      [command.operationId, command.registrationId],
    );
  });

  Future<List<RegistrationCommand>> pendingCommands(String groupId) async {
    final rows = await customSelect(
      '''
      SELECT q.operation_id, r.group_id, r.person_id, r.id AS registration_id, p.name
      FROM outbox q
      JOIN registrations r ON r.id = q.registration_id
      JOIN people p ON p.id = r.person_id
      WHERE r.group_id = ?
      ORDER BY q.sequence
    ''',
      variables: [Variable(groupId)],
    ).get();
    return rows
        .map(
          (row) => RegistrationCommand(
            operationId: row.read<String>('operation_id'),
            groupId: row.read<String>('group_id'),
            personId: row.read<String>('person_id'),
            registrationId: row.read<String>('registration_id'),
            name: row.read<String>('name'),
          ),
        )
        .toList(growable: false);
  }

  Future<void> reject(RegistrationCommand command, String reason) =>
      transaction(() async {
        await customStatement(
          '''
      UPDATE registrations SET status = 'rejected', reason = ?
      WHERE id = ? AND status = 'pending'
    ''',
          [reason, command.registrationId],
        );
        await customStatement('DELETE FROM outbox WHERE operation_id = ?', [
          command.operationId,
        ]);
      });

  Future<void> applyPage(GroupPage page) => transaction(() async {
    final group = page.group;
    await customStatement(
      '''
      INSERT INTO trip_groups (id, title, route, starts_at, capacity, cursor)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET title = excluded.title, route = excluded.route,
        starts_at = excluded.starts_at, capacity = excluded.capacity, cursor = excluded.cursor
    ''',
      [
        group.id,
        group.title,
        group.route,
        group.startsAt.toIso8601String(),
        group.capacity,
        page.cursor,
      ],
    );
    for (final change in page.changes) {
      final command = change.command;
      await customStatement(
        '''
        INSERT INTO people (id, name) VALUES (?, ?)
        ON CONFLICT(id) DO UPDATE SET name = excluded.name
      ''',
        [command.personId, command.name],
      );
      await customStatement(
        '''
        INSERT INTO registrations (id, group_id, person_id, status)
        VALUES (?, ?, ?, 'confirmed')
        ON CONFLICT(id) DO UPDATE SET status = 'confirmed', reason = NULL
      ''',
        [command.registrationId, command.groupId, command.personId],
      );
      // Only the matching journal event can retire an accepted command.
      await customStatement('DELETE FROM outbox WHERE operation_id = ?', [
        command.operationId,
      ]);
    }
    if (!page.hasMore) {
      await customStatement(
        'UPDATE trip_groups SET last_synced_at = ? WHERE id = ?',
        [DateTime.now().toUtc().toIso8601String(), group.id],
      );
    }
  });

  Future<void> forgetGroup(String groupId) => transaction(() async {
    await customStatement(
      '''
      DELETE FROM outbox WHERE registration_id IN (
        SELECT id FROM registrations WHERE group_id = ?
      )
    ''',
      [groupId],
    );
    await customStatement('DELETE FROM registrations WHERE group_id = ?', [
      groupId,
    ]);
    await customStatement('''
      DELETE FROM people WHERE NOT EXISTS (
        SELECT 1 FROM registrations WHERE person_id = people.id
      )
    ''');
    await customStatement('DELETE FROM trip_groups WHERE id = ?', [groupId]);
  });
}
