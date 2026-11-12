import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:splav/core/prototype.dart';
import 'package:splav/app/app_theme.dart';
import 'package:splav/features/trips/trip_detail.dart';
import 'package:splav/features/trips/trip_presentation.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'support/operations_fixture.dart';

void main() {
  final fixture = File('.tools/import-2026/ui-fixture.json');
  for (final width in [1400.0, 420.0]) {
    testWidgets(
      'imported season preserves missing values and historical crews at width $width',
      (tester) async {
        tz.initializeTimeZones();
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = jsonDecode(fixture.readAsStringSync()) as JsonMap;
        final catalog = source['catalog'] as JsonMap;
        final db = PrototypeDatabase(NativeDatabase.memory());
        await db.cacheCatalog(
          TripCatalog(
            teams: [
              for (final t in catalog['teams'])
                TripTeam(id: t['id'], name: t['name'], role: t['role']),
            ],
            routes: [
              for (final r in catalog['routes'])
                TripRoute(id: r['id'], teamId: r['team_id'], name: r['name']),
            ],
            trips: (catalog['trips'] as List).cast<JsonMap>(),
          ),
        );
        await db.cacheRoster(source['snapshot'] as JsonMap);
        final c = Stage1Controller(
          db,
          UnusedOperationsStage(),
          peopleApi: UnusedOperationsPeople(),
          retryInterval: null,
        );
        addTearDown(c.close);
        await c.initialize(autoSync: false);
        c.setOffline(true);
        expect(c.error, isNull);
        final imported = c.trips
            .where(
              (t) =>
                  t.importMetadata['batch_id'] ==
                  'b5b74209-69b6-5c98-8935-3e5839463a8f',
            )
            .toList();
        expect(imported, hasLength(115));
        final trip = imported.firstWhere(
          (t) => t.title.contains('01.08–02.08'),
        );
        expect(trip.dateOnly, isTrue);
        expect(trip.capacityKnown, isFalse);
        expect(TripOccupancy.read(c, trip).exceeded(trip), isFalse);
        await c.chooseTrip(trip.id);
        expect(c.error, isNull);
        expect(c.peopleView.participations, hasLength(31));
        expect(c.financeView.payments, hasLength(1));
        expect(
          c.financeView.payments.single.data['source_date_unknown'],
          isTrue,
        );
        expect(c.financeView.net(null), 1500000);
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
        expect(find.text('Исторический выезд из Excel'), findsOneWidget);
        expect(
          find.text('Лимит клиентов в источнике не указан'),
          findsOneWidget,
        );
        await tester.tap(find.text('Участники').first);
        await tester.pumpAndSettle();
        expect(find.text('Оплата не указана'), findsWidgets);
        expect(find.text('Учтено оплат'), findsOneWidget);
        expect(find.text('Остаток неизвестен'), findsOneWidget);
        await tester.tap(find.widgetWithText(ChoiceChip, 'Нет предоплаты'));
        await tester.pumpAndSettle();
        expect(
          find.text('Участников по выбранным условиям нет.'),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('Байдарки'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Байдарки'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Историческая рассадка из Excel').hitTestable(),
          findsOneWidget,
        );
        expect(find.text('Лодка 1'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      skip: !fixture.existsSync(),
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
