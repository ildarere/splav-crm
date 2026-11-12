import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/core/prototype.dart';
import 'support/finance_scenario.dart';

void main() {
  final key = Platform.environment['SPLAV_SUPABASE_KEY'];
  test(
    'family money survives restart, lost reply, lost snapshot and two-client payments',
    () async {
      final dir = await Directory.systemTemp.createTemp('splav-finance-');
      try {
        await financeScenario(
          url:
              Platform.environment['SPLAV_SUPABASE_URL'] ??
              'http://127.0.0.1:54321',
          key: key!,
          openDatabase: (profile) async => PrototypeDatabase(
            NativeDatabase(File('${dir.path}/$profile.sqlite')),
          ),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
    skip: key == null ? 'Requires SPLAV_SUPABASE_KEY' : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
