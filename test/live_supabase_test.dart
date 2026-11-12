import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:splav/core/prototype.dart';
import 'package:supabase/supabase.dart';

const _group = '00000000-0000-4000-8000-000000000004';

class _DropFirstReply implements PrototypeApi {
  _DropFirstReply(this.delegate);

  final PrototypeApi delegate;
  final sent = <String>[];
  final results = <RegistrationResult>[];

  @override
  String get groupId => delegate.groupId;

  @override
  Future<void> prepare() => delegate.prepare();

  @override
  Future<GroupPage> pull(int after) => delegate.pull(after);

  @override
  Future<RegistrationResult> submit(RegistrationCommand command) async {
    sent.add(command.operationId);
    final result = await delegate.submit(command);
    results.add(result);
    if (results.length == 1) {
      throw const SocketException('Simulated loss after server commit');
    }
    return result;
  }
}

void main() {
  final key = Platform.environment['SPLAV_SUPABASE_KEY'];
  final url =
      Platform.environment['SPLAV_SUPABASE_URL'] ?? 'http://127.0.0.1:54321';

  test(
    'two SQLite clients race, restart, and replay a lost response',
    () async {
      final originalWarning =
          driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      // Each simulated device owns a separate database file.
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(() {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = originalWarning;
      });
      final directory = await Directory.systemTemp.createTemp('splav-live-');
      addTearDown(() => directory.delete(recursive: true));

      PrototypeApi api(String organizer) {
        final client = SupabaseClient(url, key!);
        addTearDown(client.dispose);
        return SupabasePrototypeApi(
          client: client,
          email: 'organizer-$organizer@example.com',
          password: 'local-splav-demo-2026',
          groupId: _group,
        );
      }

      Future<PrototypeController> open(String name, PrototypeApi api) async {
        final controller = PrototypeController(
          PrototypeDatabase(
            NativeDatabase(File(path.join(directory.path, '$name.sqlite'))),
          ),
          api,
          retryInterval: null,
        );
        addTearDown(controller.close);
        await controller.initialize(autoSync: false);
        return controller;
      }

      final apiA = _DropFirstReply(api('a'));
      final apiB = api('b');
      var a = await open('a', apiA);
      final b = await open('b', apiB);
      await Future.wait([a.sync(), b.sync()]);
      expect(a.error, isNull);
      expect(b.error, isNull);
      expect(a.group?.capacity, 1);
      expect(
        a.participants,
        isEmpty,
        reason: 'Run against a fresh local seed.',
      );

      a.setOffline(true);
      b.setOffline(true);
      await a.addParticipant('Ирина');
      await b.addParticipant('Михаил');
      expect(a.pendingCount, 1);
      await a.close();
      a = await open('a', apiA);
      a.setOffline(true);
      expect(a.participants.single.name, 'Ирина');
      expect(a.pendingCount, 1);

      a.setOffline(false);
      b.setOffline(false);
      await Future.wait([a.sync(), b.sync()]);
      expect(apiA.results, hasLength(1));
      expect(a.error, isNotNull);
      expect(a.pendingCount, 1);
      expect(b.error, isNull);

      await a.close();
      a = await open('a', apiA);
      expect(a.pendingCount, 1);
      await Future.wait([a.sync(), b.sync()]);
      expect(a.error, isNull);
      expect(b.error, isNull);
      expect(apiA.sent, [apiA.sent.first, apiA.sent.first]);
      expect(apiA.results.last.revision, apiA.results.first.revision);
      expect(apiA.results.last.reason, apiA.results.first.reason);
      expect(a.pendingCount + b.pendingCount, 0);
      expect(a.confirmedCount, 2);
      expect(b.confirmedCount, 2);
      expect(
        a.participants
            .where((p) => p.status == ParticipantStatus.confirmed)
            .map((p) => p.id)
            .toSet(),
        b.participants
            .where((p) => p.status == ParticipantStatus.confirmed)
            .map((p) => p.id)
            .toSet(),
      );
      final rejected = [
        ...a.participants,
        ...b.participants,
      ].where((p) => p.status == ParticipantStatus.rejected);
      expect(rejected, isEmpty);
      final feed = await apiB.pull(0);
      expect(feed.changes, hasLength(2));
      expect(feed.cursor, 2);
      expect((await apiB.pull(2)).changes, isEmpty);
    },
    skip: key == null
        ? 'Requires a freshly seeded local Supabase and SPLAV_SUPABASE_KEY.'
        : false,
  );
}
