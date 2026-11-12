import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/app/app_theme.dart';
import 'package:splav/app/sync_widgets.dart';
import 'package:splav/core/prototype.dart';
import 'package:splav/features/kayaks/kayaks_screen.dart';
import 'package:splav/features/transport/transport_screen.dart';
import 'package:splav/features/staff/staff_screen.dart';
import 'package:splav/features/resources/resources_screen.dart';
import 'package:splav/features/operations/reservation_editor.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'support/operations_fixture.dart';
import 'support/ui_preview.dart';

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await loadPreviewFonts();
  });
  Widget app(Stage1Controller c, Widget page) => RepaintBoundary(
    key: const ValueKey('preview'),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: splavTheme(),
      locale: const Locale('ru', 'RU'),
      supportedLocales: const [Locale('ru', 'RU')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: DefaultTabController(
        length: 6,
        child: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(
              toolbarHeight: syncToolbarHeight(context),
              title: SyncPageTitle(title: 'Выезд · план', controller: c),
            ),
            body: page,
          ),
        ),
      ),
    ),
  );
  void size(WidgetTester tester, Size value) {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  test(
    'boat seats use explicit bounds and instructor staffing is based on the water roster',
    () async {
      expect(
        boatSeatEligible(
          {'model': 'big'},
          4,
          4,
          {'height_cm': 130, 'age_years': 8},
        ),
        isFalse,
      );
      expect(
        boatSeatEligible(
          {'model': 'big'},
          4,
          4,
          {'height_cm': 131, 'age_years': 8},
        ),
        isFalse,
      );
      for (var seat = 1; seat <= 4; seat++) {
        expect(
          boatSeatEligible(
            {'model': 'big', 'planned': true},
            4,
            seat,
            {'height_cm': 129.9, 'age_years': 8},
          ),
          isTrue,
        );
        expect(
          boatSeatEligible(
            {'model': 'big', 'planned': true},
            4,
            seat,
            {'height_cm': 120, 'age_years': 18},
          ),
          isFalse,
        );
      }
      expect(
        boatSeatEligible({'model': 'big'}, 4, 4, {'height_cm': 130}),
        isFalse,
      );
      expect(
        boatSeatEligible(
          {'model': 'rf'},
          3,
          3,
          {'height_cm': 155, 'weight_kg': 50},
        ),
        isTrue,
      );
      expect(
        boatSeatEligible(
          {'model': 'rf'},
          3,
          3,
          {'height_cm': 155, 'weight_kg': 50.01},
        ),
        isFalse,
      );
      expect(boatSeatEligible({'model': 'maigun'}, 2, 3, {}), isFalse);
      final c = await operationsFixture();
      addTearDown(c.close);
      expect(c.operationsView.requiredInstructors(c.peopleView), 1);
      expect(c.operationsView.instructorsOnWater(c.peopleView), 1);
      await c.queueOperations('ops_settings', {
        'many_children': true,
      }, expectedVersion: 1);
      expect(c.operationsView.requiredInstructors(c.peopleView), 2);
      final people = PeopleView(
        participations: [
          for (var i = 0; i < 35; i++)
            Participation({
              'id': '$i',
              'person_id': '$i',
              'booking_id': 'b',
              'trip_id': 't',
              'role': 'client',
              'status': 'confirmed',
            }),
        ],
      );
      expect(const OperationsView().requiredInstructors(people), 2);
    },
  );

  test(
    'SQLite retains placements, boarding predecessor UUIDs and previous money operations across restart',
    () async {
      final dir = await Directory.systemTemp.createTemp('splav-ops-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/ops.sqlite');
      var c = await operationsFixture(
        database: PrototypeDatabase(NativeDatabase(file)),
      );
      await c.queueFinance('add_payment', {
        'booking_id': 'family',
        'amount_kopeks': 50000,
        'direction': 'income',
        'method': 'cash',
        'occurred_at': DateTime.now().toUtc().toIso8601String(),
        'allocations': [
          {'participation_id': 'p2', 'amount_kopeks': 50000},
        ],
      });
      await c.queueOperations('ops_crew', {
        'subject_kind': 'participant',
        'subject_id': 'p2',
        'reservation_id': 'rfBooking',
        'seat': 3,
      });
      await c.queueOperations('ops_presence', {
        'subject_kind': 'participant',
        'subject_id': 'p2',
        'reservation_id': 'rfBooking',
        'present': true,
      });
      final first = c.operationsView.commands.last;
      await c.queueOperations('ops_presence', {
        'subject_kind': 'participant',
        'subject_id': 'p2',
        'reservation_id': 'rfBooking',
        'present': false,
        'reason': 'Вернулся на берег',
      });
      final ids = c.peopleView.commands.map((q) => q.id).toList();
      expect(
        c.operationsView.commands.last.payload['previous_id'],
        first.payload['id'],
      );
      await c.close();
      c = await operationsFixture(
        database: PrototypeDatabase(NativeDatabase(file)),
        seed: false,
      );
      addTearDown(c.close);
      expect(c.peopleView.commands.map((q) => q.id), ids);
      expect(c.operationsView.crew('p2')?['seat'], 3);
      expect(
        c.operationsView.fact('rfBooking', 'participant', 'p2')?['present'],
        isFalse,
      );
      expect(c.financeView.net('family'), 50000);
      expect(
        (await c.database.customSelect('PRAGMA user_version').getSingle())
            .data
            .values
            .single,
        3,
      );
    },
  );

  testWidgets(
    'an unassigned small adult takes the RF extra seat and shows the authoritative previous plan',
    (tester) async {
      size(tester, const Size(1440, 1200));
      final c = await operationsFixture();
      addTearDown(c.close);
      await tester.pumpWidget(app(c, KayaksScreen(controller: c)));
      await tester.pumpAndSettle();
      await captureUi(tester, 'kayaks-desktop');
      await tester.scrollUntilVisible(
        find.byTooltip('Назначить в байдарку'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Назначить в байдарку'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Назначить в байдарку'));
      await tester.pumpAndSettle();
      final field = find.widgetWithText(
        DropdownButtonFormField<String>,
        'Байдарка',
      );
      tester.widget<DropdownButtonFormField<String>>(field).onChanged!(
        'rfBooking',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(
          ChoiceChip,
          '3 · Дополнительное · ≤ 155 см и ≤ 50 кг',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Назначить место'));
      await tester.pumpAndSettle();
      expect(c.operationsView.crew('p2')?['reservation_id'], 'rfBooking');
      expect(c.operationsView.commands.single.expectedVersion, 0);
      expect(c.operationsView.crew('p2')?['pending'], isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'outbound changes independently and an existing physical boarding becomes a visible discrepancy',
    (tester) async {
      size(tester, const Size(1440, 1200));
      final c = await operationsFixture();
      addTearDown(c.close);
      await tester.pumpWidget(app(c, TransportScreen(controller: c)));
      await tester.pumpAndSettle();
      expect(
        c.operationsView.travel.where((t) => t['reservation_id'] == 'ride'),
        hasLength(2),
      );
      await captureUi(tester, 'transport-desktop');
      await tester.ensureVisible(find.byTooltip('Указать проезд').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Указать проезд').first);
      await tester.pumpAndSettle();
      tester
          .widget<DropdownButtonFormField<String>>(
            find.widgetWithText(
              DropdownButtonFormField<String>,
              'Способ проезда',
            ),
          )
          .onChanged!('self');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить проезд'));
      await tester.pumpAndSettle();
      expect(
        c.operationsView.journey('participant', 'p0', 'outbound')?['mode'],
        'self',
      );
      expect(
        c.operationsView.journey('participant', 'p0', 'return')?['mode'],
        'self',
      );
      expect(
        c.operationsView.latestPresence.values.where(
          (f) => f['present'] == true,
        ),
        hasLength(1),
      );
      expect(c.operationsView.issues(c.peopleView), hasLength(1));
      expect(find.text('Факт присутствия расходится с планом'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'staff, fleet and reservation forms fit a phone at 200 percent text',
    (tester) async {
      size(tester, const Size(390, 844));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final c = await operationsFixture();
      addTearDown(c.close);
      for (final page in [
        KayaksScreen(controller: c),
        TransportScreen(controller: c),
        StaffScreen(controller: c),
      ]) {
        await tester.pumpWidget(app(c, page));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await captureUi(tester, 'staff-phone-200');
      await tester.pumpWidget(
        app(c, ResourcesScreen(controller: c, kind: 'boat')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Добавить лодку'));
      await tester.pumpAndSettle();
      expect(find.text('Новая запись'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(
          c,
          Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => editReservation(context, c, 'ride'),
                child: const Text('Открыть рейс'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть рейс'));
      await tester.pumpAndSettle();
      expect(find.text('Сохранить рейс'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'provisional cancellation frees plans and leaves presence facts and money intact',
    () async {
      final c = await operationsFixture();
      addTearDown(c.close);
      await c.setParticipationStatus({'p0'}, 'cancelled');
      expect(c.operationsView.crew('p0')?['reservation_id'], isNull);
      expect(
        c.operationsView.journey('participant', 'p0', 'outbound')?['mode'],
        'unset',
      );
      expect(
        c.operationsView.fact('ride', 'participant', 'p0')?['present'],
        isTrue,
      );
      expect(c.operationsView.issues(c.peopleView), hasLength(1));
      expect(c.financeView.net('family'), 0);
    },
  );

  test(
    'default setup contains only known units, named staff and editable quantity references',
    () {
      var next = 0;
      final setup = defaultOperationsSetup(() => 'test-${next++}');
      final rows = operationRows(setup['items']);
      expect(rows.where((r) => r['kind'] == 'boat'), hasLength(2));
      expect(rows.where((r) => r['kind'] == 'employee').map((r) => r['name']), [
        'Лиза',
        'Анна Орлова',
        'Варя',
      ]);
      expect(
        rows.where((r) => r['kind'] == 'vehicle').map((r) => r['capacity']),
        [30, 20, 4],
      );
      expect((setup['reference'] as Map)['rf_min'], 20);
    },
  );
}
