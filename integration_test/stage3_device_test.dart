import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:splav/core/prototype.dart';
import 'package:splav/app/app_theme.dart';
import 'package:splav/features/payments/finance_screen.dart';
import 'package:splav/features/bookings/roster_screen.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import '../test/support/finance_scenario.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  const url = String.fromEnvironment('SUPABASE_URL'),
      key = String.fromEnvironment('SUPABASE_ANON_KEY');
  testWidgets(
    'native family ledger, durable queue and safe financial replay',
    (tester) async {
      final scope = 'stage3-native-${DateTime.now().microsecondsSinceEpoch}';
      await financeScenario(
        url: url,
        key: key,
        openDatabase: (profile) =>
            PrototypeDatabase.open(scope: '$scope-$profile'),
        inspect: (c) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: splavTheme(),
              home: DefaultTabController(
                length: 3,
                child: Scaffold(body: FinanceScreen(controller: c)),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Получить оплату'), findsOneWidget);
          expect(find.text('Семейная заявка · 3 чел.'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(
            MaterialApp(
              theme: splavTheme(),
              home: DefaultTabController(
                length: 3,
                child: Scaffold(body: RosterScreen(controller: c)),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text('Предоплата · 500 ₽/чел.'),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Предоплата · 500 ₽/чел.'));
          await tester.pumpAndSettle();
          // Two people have paid fully; the third has 400 ₽. Only 100 ₽ is due
          // to reach the configured deposit, independent of platform or viewport.
          expect(
            tester
                .widget<TextFormField>(
                  find.widgetWithText(TextFormField, 'Сумма, ₽'),
                )
                .controller!
                .text,
            '100,00',
          );
          await tester.tap(find.text('Сохранить платёж'));
          await tester.pumpAndSettle();
          expect(c.financeView.commands.single.payload['amount_kopeks'], 10000);
          expect(c.financeView.net(c.peopleView.bookings.single.id), 250000);
          c.setOffline(false);
          await c.sync();
          expect(c.error, isNull);
          expect(c.financeView.commands, isEmpty);
          expect(c.financeView.net(c.peopleView.bookings.single.id), 250000);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    },
    skip: url.isEmpty || key.isEmpty,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
