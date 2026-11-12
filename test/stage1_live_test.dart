import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/core/prototype.dart';
import 'package:supabase/supabase.dart';
import 'package:uuid/uuid.dart';
import 'stage1_fixture.dart';

void main() {
  final key = Platform.environment['SPLAV_SUPABASE_KEY'];
  final url =
      Platform.environment['SPLAV_SUPABASE_URL'] ?? 'http://127.0.0.1:54321';
  test(
    'live two-client trips, offline restart, conflict, reply replay and v1 upgrade',
    () async {
      final warning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(
        () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = warning,
      );
      final directory = await Directory.systemTemp.createTemp(
        'splav-stage1-live-',
      );
      addTearDown(() => directory.delete(recursive: true));
      Stage1Api api() {
        final client = SupabaseClient(
          url,
          key!,
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        addTearDown(client.dispose);
        return SupabaseStage1Api(
          client: client,
          prepare: () async {
            if (client.auth.currentSession == null) {
              await client.auth.signInWithPassword(
                email: 'organizer-a@example.com',
                password: 'local-splav-demo-2026',
              );
            }
          },
        );
      }

      Future<Stage1Controller> open(String name, Stage1Api remote) async {
        final controller = Stage1Controller(
          PrototypeDatabase(
            NativeDatabase(File('${directory.path}/$name.sqlite')),
          ),
          remote,
          retryInterval: null,
        );
        addTearDown(controller.close);
        await controller.initialize(autoSync: false);
        return controller;
      }

      final suffix = const Uuid().v4();
      final remote = _DropSaveReply(api());
      var a = await open('a', remote);
      var b = await open('b', api());
      await a.sync();
      expect(a.error, isNull);
      a.setOffline(true);
      final first = await a.saveTrip(
        draft(title: 'Проверка A $suffix', capacity: 5),
      );
      final second = await a.saveTrip(
        draft(
          title: 'Проверка B $suffix',
          capacity: 9,
          startsAt: DateTime.utc(2027, 6, 15, 8),
        ),
      );
      remote.dropNext = true;
      a.setOffline(false);
      await a.sync();
      expect(a.error, isNotNull);
      expect(a.pendingCommandCount, 2);
      final original = remote.operationIds.single;
      await a.close();
      a = await open('a', remote);
      await a.sync();
      expect(a.error, isNull);
      expect(remote.operationIds.take(2), [original, original]);
      expect(a.pendingCommandCount, 0);
      expect(a.trips.firstWhere((t) => t.id == first).isDownloaded, isTrue);
      expect(a.trips.firstWhere((t) => t.id == second).capacity, 9);

      await b.sync();
      b.setOffline(true);
      await b.setDownloaded(first, true);
      await b.setDownloaded(second, true);
      b.setOffline(false);
      await b.sync();
      expect(b.error, isNull);
      await b.close();
      b = await open('b', api());
      b.setOffline(true);
      await b.chooseTrip(first);
      expect(b.selectedTrip?.isDownloaded, isTrue);
      await b.chooseTrip(second);
      expect(b.selectedTrip?.isDownloaded, isTrue);
      expect(b.selectedTrip?.startsAt, DateTime.utc(2027, 6, 15, 8));

      a.setOffline(true);
      await a.saveTrip(draft(title: 'Изменено A $suffix'), tripId: first);
      await b.saveTrip(draft(title: 'Изменено B $suffix'), tripId: first);
      a.setOffline(false);
      await a.sync();
      b.setOffline(false);
      await b.sync();
      expect(b.selectedTrip?.syncState, TripSyncState.conflict);
      expect(b.selectedTrip?.title, 'Изменено B $suffix');
      expect(b.selectedTrip?.serverTrip?.title, 'Изменено A $suffix');
      await b.retryConflict(first);
      await b.sync();
      expect(b.error, isNull);
      expect(b.selectedTrip?.syncState, TripSyncState.synced);

      final legacyFile = File('${directory.path}/legacy.sqlite');
      createV1Fixture(
        legacyFile,
        groupId: first,
        personId: const Uuid().v4(),
        registrationId: const Uuid().v4(),
        operationId: const Uuid().v4(),
      );
      final legacy = await open('legacy', api());
      expect(legacy.pendingCommandCount, 1);
      await legacy.sync();
      expect(legacy.error, isNull);
      expect(legacy.pendingCommandCount, 0);
      await legacy.chooseTrip(first);
      expect(
        legacy.selectedParticipants.any(
          (p) =>
              p.name == 'Старая очередь' &&
              p.status == ParticipantStatus.confirmed,
        ),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: key == null
        ? 'Requires local seeded Supabase and SPLAV_SUPABASE_KEY.'
        : false,
  );
}

class _DropSaveReply implements Stage1Api {
  _DropSaveReply(this.delegate);
  final Stage1Api delegate;
  final operationIds = <String>[];
  bool dropNext = false;
  @override
  Future<void> prepare() => delegate.prepare();
  @override
  Future<TripCatalog> catalog() => delegate.catalog();
  @override
  Future<TripRoute> createRoute(RouteCommand command) =>
      delegate.createRoute(command);
  @override
  PrototypeApi groupApi(String tripId) => delegate.groupApi(tripId);
  @override
  Future<TripSaveResult> saveTrip(TripCommand command) async {
    operationIds.add(command.operationId);
    final result = await delegate.saveTrip(command);
    if (dropNext) {
      dropNext = false;
      throw const SocketException('Commit succeeded, response lost');
    }
    return result;
  }
}
