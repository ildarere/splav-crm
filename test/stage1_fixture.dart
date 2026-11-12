import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'package:splav/core/prototype.dart';

const demoTeam = '00000000-0000-4000-8000-000000000010';
const demoRoute = '00000000-0000-4000-8000-000000000020';
const demoGroup = '00000000-0000-4000-8000-000000000001';

TripDraft draft({
  String title = 'Выезд',
  int capacity = 5,
  DateTime? startsAt,
  String? routeId,
}) {
  final starts = startsAt ?? DateTime.utc(2027, 5, 12, 6);
  return TripDraft(
    teamId: demoTeam,
    title: title,
    routeId: routeId ?? demoRoute,
    startsAt: starts,
    endsAt: starts.add(const Duration(hours: 8)),
    timeZone: 'Europe/Saratov',
    meetingPoint: 'Мост',
    meetingAt: starts.subtract(const Duration(hours: 1)),
    responsibleNames: 'Организатор',
    capacity: capacity,
    basePriceKopecks: 150000,
    notes: 'Тестовые данные',
    status: 'open',
  );
}

Map<String, dynamic> serverTrip(
  String id,
  TripDraft draft, {
  int version = 1,
}) => {
  'id': id,
  'team_id': draft.teamId,
  'route': 'Тестовый маршрут',
  'metadata_version': version,
  ...draft.toJson(),
};

void createV1Fixture(
  File file, {
  String groupId = demoGroup,
  String personId = '00000000-0000-4000-8000-000000000091',
  String registrationId = '00000000-0000-4000-8000-000000000092',
  String operationId = '00000000-0000-4000-8000-000000000093',
  String? lastSyncedAt = '2026-11-04T12:00:00Z',
}) {
  final db = sqlite3.open(file.path);
  try {
    db.execute('''
      CREATE TABLE trip_groups(id TEXT PRIMARY KEY NOT NULL,title TEXT NOT NULL,
        route TEXT NOT NULL,starts_at TEXT NOT NULL,capacity INTEGER NOT NULL,
        cursor INTEGER NOT NULL,last_synced_at TEXT);
      CREATE TABLE people(id TEXT PRIMARY KEY NOT NULL,name TEXT NOT NULL);
      CREATE TABLE registrations(id TEXT PRIMARY KEY NOT NULL,group_id TEXT NOT NULL REFERENCES trip_groups(id),
        person_id TEXT NOT NULL REFERENCES people(id),status TEXT NOT NULL,reason TEXT,UNIQUE(group_id,person_id));
      CREATE TABLE outbox(sequence INTEGER PRIMARY KEY,operation_id TEXT UNIQUE NOT NULL,
        registration_id TEXT UNIQUE NOT NULL REFERENCES registrations(id));
      PRAGMA user_version=1;
    ''');
    db.execute('INSERT INTO trip_groups VALUES (?,?,?,?,?,?,?)', [
      groupId,
      'Старый выезд',
      'Тестовый маршрут',
      '2027-05-12T06:00:00Z',
      5,
      0,
      lastSyncedAt,
    ]);
    db.execute('INSERT INTO people VALUES (?,?)', [personId, 'Старая очередь']);
    db.execute("INSERT INTO registrations VALUES (?,?,?,'pending',NULL)", [
      registrationId,
      groupId,
      personId,
    ]);
    db.execute(
      'INSERT INTO outbox(operation_id,registration_id) VALUES (?,?)',
      [operationId, registrationId],
    );
  } finally {
    db.close();
  }
}
