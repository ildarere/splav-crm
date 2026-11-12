import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:splav/core/prototype.dart';
import 'package:splav/app/app_theme.dart';
import 'package:splav/features/trips/trip_detail.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import '../test/support/operations_scenario.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  const url = String.fromEnvironment('SUPABASE_URL'),
      key = String.fromEnvironment('SUPABASE_ANON_KEY');
  testWidgets(
    'native fleet, separate transport directions, boarding history and durable two-client sync',
    (tester) async {
      final scope = 'stage45-${DateTime.now().microsecondsSinceEpoch}';
      await operationsScenario(
        url: url,
        key: key,
        openDatabase: (profile) =>
            PrototypeDatabase.open(scope: '$scope-$profile'),
        inspect: (c) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: splavTheme(),
              locale: const Locale('ru', 'RU'),
              supportedLocales: const [Locale('ru', 'RU')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: TripDetail(controller: c),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Готовность к выезду'), findsOneWidget);
          await tester.ensureVisible(find.text('Трансфер'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Трансфер'));
          await tester.pumpAndSettle();
          expect(
            find.text('Факт присутствия расходится с планом').hitTestable(),
            findsOneWidget,
          );
          expect(find.text('Факт верен').hitTestable(), findsOneWidget);
          expect(find.text('Ошибка отметки').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    },
    skip: url.isEmpty || key.isEmpty,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
