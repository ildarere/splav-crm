import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:splav/app/stage1_app.dart';
import 'package:splav/core/session_store.dart';
import 'package:supabase/supabase.dart' show Session;
import 'package:timezone/data/latest_all.dart' as tz;

class _Disconnected extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'PROXY 127.0.0.1:9';
    client.connectionTimeout = const Duration(seconds: 1);
    return client;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_ANON_KEY');

  testWidgets(
    'working login restores its expired protected session without a network',
    (tester) async {
      tz.initializeTimeZones();
      final profile =
          'login-acceptance-${DateTime.now().microsecondsSinceEpoch}';
      final store = SessionStore(scope: [url, profile].join('\n'));
      final previousOverrides = HttpOverrides.current;
      addTearDown(() async {
        HttpOverrides.global = previousOverrides;
        await store.delete();
      });
      Future<void> waitFor(Finder finder) async {
        for (var i = 0; i < 120 && finder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(finder, findsWidgets);
      }

      Widget app() => Stage1App(url: url, anonKey: key, profile: profile);
      await tester.pumpWidget(app());
      final login = find.widgetWithText(FilledButton, 'Войти');
      await waitFor(login);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'organizer-c@example.com',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'local-splav-demo-2026',
      );
      await tester.tap(login);
      await waitFor(find.text('Субботний сплав'));
      expect(await store.read(), isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));

      final saved = jsonDecode((await store.read())!) as Map<String, dynamic>;
      // Exercise local expiry with the server transport blocked below.
      final token = (saved['access_token'] as String).split('.');
      final payload =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(token[1]))),
              )
              as Map<String, dynamic>;
      payload['exp'] = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60;
      token[1] = base64Url
          .encode(utf8.encode(jsonEncode(payload)))
          .replaceAll('=', '');
      saved['access_token'] = token.join('.');
      expect(Session.fromJson(saved)!.isExpired, isTrue);
      await store.write(jsonEncode(saved));

      HttpOverrides.global = _Disconnected();
      await tester.pumpWidget(app());
      await waitFor(find.text('Субботний сплав'));
      expect(find.widgetWithText(FilledButton, 'Войти'), findsNothing);
      await waitFor(find.textContaining('Не удалось завершить обмен'));
      // Allow the SDK's underlying refresh retries to finish after our timeout.
      await tester.pump(const Duration(seconds: 25));
      expect(find.text('Субботний сплав'), findsWidgets);
      expect(find.widgetWithText(FilledButton, 'Войти'), findsNothing);
      expect(await store.read(), isNotNull);
      final logout = find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            widget.tooltip == 'Выйти из аккаунта' &&
            widget.onPressed != null,
      );
      await waitFor(logout);
      HttpOverrides.global = previousOverrides;
      await tester.tap(logout);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Выйти'));
      await waitFor(login);
      expect(await store.read(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
    skip: url.isEmpty || key.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
