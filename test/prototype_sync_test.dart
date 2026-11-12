import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/core/prototype.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('splav-sync-');
    file = File('${directory.path}${Platform.pathSeparator}client.sqlite');
  });

  tearDown(() => directory.delete(recursive: true));

  Future<PrototypeController> open(_TestServer api) async {
    final controller = PrototypeController(
      PrototypeDatabase(NativeDatabase(file)),
      api,
      retryInterval: null,
    );
    addTearDown(controller.close);
    await controller.initialize(autoSync: false);
    return controller;
  }

  test(
    'local rows and their pending operation survive closing SQLite',
    () async {
      final api = _TestServer();
      final first = await open(api);
      await first.sync();
      first.setOffline(true);
      await first.addParticipant('Анна');
      expect(first.pendingCount, 1);
      expect(api.calls, isEmpty);
      await first.close();

      final reopened = await open(api);
      expect(reopened.group?.title, 'Тестовый сплав');
      expect(reopened.participants.single.name, 'Анна');
      expect(reopened.participants.single.status, ParticipantStatus.pending);

      await reopened.sync();
      expect(reopened.confirmedCount, 1);
      expect(reopened.pendingCount, 0);
      expect(api.calls, hasLength(1));
    },
  );

  test(
    'repeats the same operation after a committed response is lost',
    () async {
      final api = _TestServer()..dropNextSubmitResponse = true;
      final first = await open(api);
      await first.sync();
      first.setOffline(true);
      await first.addParticipant('Борис');
      first.setOffline(false);
      await first.sync();
      expect(first.pendingCount, 1);
      expect(first.error, isNotNull);
      expect(api.changes, hasLength(1));
      await first.close();

      final reopened = await open(api);
      await reopened.sync();
      expect(api.calls, hasLength(2));
      expect(api.calls.first, api.calls.last);
      expect(api.changes, hasLength(1));
      expect(reopened.participants.single.status, ParticipantStatus.confirmed);
      expect(reopened.pendingCount, 0);
      expect(reopened.error, isNull);
    },
  );

  test(
    'keeps an accepted command visible if pulling its event fails',
    () async {
      final api = _TestServer();
      final first = await open(api);
      await first.sync();
      first.setOffline(true);
      await first.addParticipant('Вера');
      api.dropNextPullResponse = true;
      first.setOffline(false);
      await first.sync();
      expect(first.participants.single.status, ParticipantStatus.pending);
      await first.close();

      final reopened = await open(api);
      await reopened.sync();
      expect(api.calls.first, api.calls.last);
      expect(reopened.participants.single.status, ParticipantStatus.confirmed);
    },
  );
}

class _TestServer implements PrototypeApi {
  final _group = PrototypeGroup(
    id: 'test-group',
    title: 'Тестовый сплав',
    route: 'Сбор у старта',
    startsAt: DateTime.utc(2027, 5),
    capacity: 1,
  );
  final calls = <String>[];
  final changes = <RegistrationChange>[];
  final _receipts = <String, RegistrationResult>{};
  bool dropNextSubmitResponse = false;
  bool dropNextPullResponse = false;

  @override
  String get groupId => _group.id;

  @override
  Future<void> prepare() async {}

  @override
  Future<GroupPage> pull(int after) async {
    if (dropNextPullResponse) {
      dropNextPullResponse = false;
      throw TimeoutException('Lost journal response');
    }
    return GroupPage(
      group: _group,
      changes: changes.where((change) => change.revision > after).toList(),
      cursor: changes.length,
      hasMore: false,
    );
  }

  @override
  Future<RegistrationResult> submit(RegistrationCommand command) async {
    calls.add(command.operationId);
    final result = _receipts.putIfAbsent(command.operationId, () {
      if (changes.length >= _group.capacity) {
        return const RegistrationResult.rejected('capacity_reached');
      }
      final revision = changes.length + 1;
      changes.add(RegistrationChange(revision: revision, command: command));
      return RegistrationResult.accepted(revision);
    });
    if (dropNextSubmitResponse) {
      dropNextSubmitResponse = false;
      throw TimeoutException('Lost command response');
    }
    return result;
  }
}
