import 'package:flutter/material.dart';
import 'package:supabase/supabase.dart';
import 'package:timezone/data/latest_all.dart' as tz;

import 'app/prototype_app.dart';
import 'app/stage1_app.dart';
import 'core/prototype.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  const config = _PrototypeConfig();
  const demo = bool.fromEnvironment('SPLAV_DEMO');
  runApp(
    demo
        ? PrototypeApp(open: config.open)
        : const Stage1App(
            url: _PrototypeConfig.url,
            anonKey: _PrototypeConfig.anonKey,
            profile: _PrototypeConfig.profile,
            legacyGroupId: _PrototypeConfig.groupId,
          ),
  );
}

class _PrototypeConfig {
  const _PrototypeConfig();

  static const url = String.fromEnvironment('SUPABASE_URL');
  static const anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const email = String.fromEnvironment('SPLAV_EMAIL');
  static const password = String.fromEnvironment('SPLAV_PASSWORD');
  static const groupId = String.fromEnvironment(
    'SPLAV_GROUP_ID',
    defaultValue: '00000000-0000-4000-8000-000000000001',
  );
  static const profile = String.fromEnvironment('SPLAV_PROFILE');

  Future<PrototypeSession?> open() async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const ['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        anonKey.isEmpty ||
        email.isEmpty ||
        password.isEmpty) {
      return null;
    }

    final client = SupabaseClient(
      url,
      anonKey,
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    PrototypeController? controller;
    try {
      final database = await PrototypeDatabase.open(
        scope: [url, email.toLowerCase(), groupId, profile].join('\n'),
      );
      final api = SupabasePrototypeApi(
        client: client,
        email: email,
        password: password,
        groupId: groupId,
      );
      controller = PrototypeController(database, api);
      await controller.initialize();
      return PrototypeSession(controller, client.dispose);
    } catch (_) {
      try {
        await controller?.close();
      } finally {
        await client.dispose();
      }
      rethrow;
    }
  }
}
