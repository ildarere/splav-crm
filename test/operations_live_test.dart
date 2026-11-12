import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/core/prototype.dart';
import 'support/operations_scenario.dart';

void main() {
  final key = Platform.environment['SPLAV_SUPABASE_KEY'] ?? '';
  test(
    'two real clients retain resource queue and boarding across restarts and lost replies',
    () async {
      final dir = await Directory.systemTemp.createTemp('splav-live-ops-');
      try {
        await operationsScenario(
          url:
              Platform.environment['SPLAV_SUPABASE_URL'] ??
              'http://127.0.0.1:54321',
          key: key,
          openDatabase: (profile) async => PrototypeDatabase(
            NativeDatabase(File('${dir.path}/$profile.sqlite')),
          ),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
    skip: key.isEmpty,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
