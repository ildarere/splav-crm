import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/core/prototype.dart';
import 'package:splav/app/instructor_brand.dart';
import 'package:splav/features/operations/reservation_editor.dart';
import 'package:splav/features/people/people_screen.dart';
import 'package:splav/features/people/worker_schedule.dart';
import 'package:splav/features/people/work_schedule_screen.dart';
import 'package:splav/features/bookings/roster_screen.dart';
import 'package:splav/features/cabins/cabins_screen.dart';
import 'package:splav/features/transport/transport_screen.dart';
import 'package:splav/features/kayaks/kayaks_screen.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'support/operations_fixture.dart';
import 'stage1_fixture.dart';

void main() {
  setUpAll(tz.initializeTimeZones);
  Widget app(Widget page) => MaterialApp(
    locale: const Locale('ru', 'RU'),
    supportedLocales: const [Locale('ru', 'RU')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: Scaffold(body: page),
  );
  void viewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('Cabins accept mouse dragging and a configurable extra bed', (
    tester,
  ) async {
    viewport(tester);
    final c = await operationsFixture();
    addTearDown(c.close);
    await tester.pumpWidget(
      app(
        Theme(
          data: ThemeData(platform: TargetPlatform.windows),
          child: CabinsScreen(controller: c),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Инструктор'), findsNothing);
    expect(find.textContaining('№ 13 ·'), findsNothing);
    expect(find.text('№ 5 · 0/4'), findsOneWidget);
    expect(find.text('№ 6 · 0/2'), findsOneWidget);
    expect(find.text('№ 21 · 0/2'), findsOneWidget);
    final start = tester.getCenter(find.widgetWithText(ActionChip, 'Взрослый'));
    final destination = tester.getCenter(find.text('№ 1 · 0/4'));
    final mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(24, 0));
    await mouse.moveTo(destination);
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();
    expect(c.operationsView.settings['cabins']['assignments'], {'p0': 1});
    await tester.tap(find.byTooltip('Добавить дополнительное место').first);
    await tester.pumpAndSettle();
    expect(find.text('№ 1 · 1/5'), findsOneWidget);

    await tester.pumpWidget(
      app(
        Theme(
          data: ThemeData(platform: TargetPlatform.android),
          child: CabinsScreen(controller: c),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final touch = await tester.startGesture(
      tester.getCenter(find.widgetWithText(ActionChip, 'Взрослый')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await touch.moveTo(tester.getCenter(find.text('Без домика · 2')));
    await tester.pump();
    await touch.up();
    await tester.pumpAndSettle();
    expect(c.operationsView.settings['cabins']['assignments'], isEmpty);
  });

  testWidgets(
    'Cancelled client can be restored in a new company without a second participation',
    (tester) async {
      viewport(tester);
      final c = await operationsFixture();
      addTearDown(c.close);
      await c.setParticipationStatus({'p0'}, 'cancelled');
      await tester.pumpWidget(app(RosterScreen(controller: c)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Список отмены'));
      await tester.pumpAndSettle();
      expect(find.text('Взрослый'), findsOneWidget);
      final cancelledCard = find.ancestor(
        of: find.text('Взрослый'),
        matching: find.byType(Card),
      );
      expect(
        find.descendant(of: cancelledCard, matching: find.text('Семья')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: cancelledCard, matching: find.text('Отменено')),
        findsOneWidget,
      );
      await c.discardPeopleChange(c.peopleView.commands.last.id);
      final snapshot = (await c.database.serverRoster(demoGroup))!;
      (snapshot['participations'] as List).firstWhere(
        (p) => p['id'] == 'p0',
      )['status'] = 'cancelled';
      await c.database.cacheRoster({...snapshot, 'revision': 2});
      await c.initialize(autoSync: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Вернуть'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отдельным участником'));
      await tester.pumpAndSettle();
      final command = c.peopleView.commands.last;
      final restored = c.peopleView.participations.singleWhere(
        (p) => p.id == 'p0',
      );
      expect(restored.bookingId, command.payload['separate_booking_id']);
      expect(restored.requestedStatus, 'confirmed');
      expect(
        c.peopleView.bookings
            .singleWhere((b) => b.id == restored.bookingId)
            .contactPersonId,
        'person0',
      );
      expect(
        c.peopleView.participations.where((p) => p.personId == 'person0'),
        hasLength(1),
      );
      await c.setParticipationStatus({'p1'}, 'waiting');
      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Резерв'));
      await tester.pumpAndSettle();
      expect(find.text('Место в очереди · 1'), findsOneWidget);
      expect(find.text('На устройстве'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Common schedule offers parallel trips and kitchen from one day cell',
    (tester) async {
      viewport(tester);
      final c = await operationsFixture();
      addTearDown(c.close);
      await c.database.cacheCatalog(
        TripCatalog(
          teams: const [TripTeam(id: demoTeam, name: 'Команда', role: 'admin')],
          routes: const [
            TripRoute(id: demoRoute, teamId: demoTeam, name: 'Река'),
          ],
          trips: [
            serverTrip(demoGroup, draft(title: 'Первый сплав')),
            serverTrip('second-trip', draft(title: 'Второй сплав')),
          ],
        ),
      );
      await c.database.cachePeople({
        'teams': [
          {'id': demoTeam, 'revision': 1},
        ],
        'people': [
          {
            'id': 'worker-card',
            'team_id': demoTeam,
            'name': 'Работник графика',
            'version': 1,
            'is_worker': true,
            'work_resource_id': 'worker',
            'work_roles': ['water_instructor', 'camp_kitchen', 'trip_cook'],
          },
        ],
      });
      await c.initialize(autoSync: false);
      await tester.pumpWidget(
        app(WorkScheduleScreen(controller: c, initialTrip: c.selectedTrip)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ср, 12.05'), findsOneWidget);
      expect(find.text('Работник графика'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add).at(2));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Команда сопровождения · Первый сплав'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Команда сопровождения · Второй сплав'),
        findsOneWidget,
      );
      expect(find.text('Добавить · Кухня лагеря'), findsOneWidget);
      await tester.tap(
        find.textContaining('Команда сопровождения · Второй сплав'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('0 · Оплачено'));
      await tester.tap(find.text('Сохранить смену'));
      await tester.pumpAndSettle();
      final command = c.peopleView.commands.last;
      expect(command.tripId, 'second-trip');
      expect(command.payload['role'], 'water_instructor');
      expect(command.payload['paid'], isTrue);
      expect(find.byTooltip('Оплачено'), findsOneWidget);
      expect(
        find.textContaining('Инструктор на воде · Второй сплав'),
        findsOneWidget,
      );
      await tester.tap(find.text('Месяц'));
      await tester.pumpAndSettle();
      expect(find.text('01.05.2027 — 31.05.2027'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Kayak editor hides schedule and buffers and saves exact trip times',
    (tester) async {
      viewport(tester);
      final c = await operationsFixture();
      addTearDown(c.close);
      JsonMap? result;
      final booking = c.operationsView.bookings('boat').first;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<JsonMap>(
                  context: context,
                  builder: (_) => ReservationEditor(
                    controller: c,
                    kind: 'boat',
                    booking: booking,
                  ),
                );
              },
              child: const Text('Открыть'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Начало ·'), findsNothing);
      expect(find.textContaining('Окончание ·'), findsNothing);
      expect(
        find.widgetWithText(TextFormField, 'Подготовка до начала, мин'),
        findsNothing,
      );
      expect(
        find.widgetWithText(TextFormField, 'Возврат / освобождение после, мин'),
        findsNothing,
      );
      expect(find.widgetWithText(TextFormField, 'Примечание'), findsNothing);
      await tester.tap(find.text('Сохранить бронь'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(
        DateTime.parse(result!['starts_at'] as String),
        c.selectedTrip!.startsAt,
      );
      expect(
        DateTime.parse(result!['ends_at'] as String),
        c.selectedTrip!.endsAt,
      );
      expect(result!['prep_minutes'], 0);
      expect(result!['return_minutes'], 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Instructor is absent from client roster and transfer and uses brand mark on water',
    (tester) async {
      viewport(tester);
      final c = await operationsFixture();
      addTearDown(c.close);
      await tester.pumpWidget(app(RosterScreen(controller: c)));
      await tester.pumpAndSettle();
      expect(find.text('Инструктор'), findsNothing);
      expect(find.textContaining('Участников 3'), findsOneWidget);
      await tester.pumpWidget(app(TransportScreen(controller: c)));
      await tester.pumpAndSettle();
      expect(find.text('Инструктор'), findsNothing);
      await tester.pumpWidget(app(KayaksScreen(controller: c)));
      await tester.pumpAndSettle();
      expect(find.byType(InstructorMark), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Worker is created from People and has a persistent independent schedule with overlap protection',
    (tester) async {
      viewport(tester);
      final c = await operationsFixture();
      addTearDown(c.close);
      await tester.pumpWidget(app(PeopleScreen(controller: c)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Новый работник'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Имя и фамилия *'),
        'Работник графика',
      );
      await tester.tap(find.widgetWithText(FilterChip, 'Склад'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      final worker = c.peopleView.people.singleWhere(
        (p) => p.name == 'Работник графика',
      );
      expect(worker.isWorker, isTrue);
      expect(worker.workRoles, ['warehouse']);
      await tester.ensureVisible(find.text('График работы'));
      await tester.tap(find.text('График работы'));
      await tester.pumpAndSettle();
      expect(find.byType(WorkerSchedule), findsOneWidget);
      await tester.tap(find.text('Добавить смену'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить смену'));
      await tester.pumpAndSettle();
      var saved = c.peopleView.person(worker.id)!;
      expect(saved.workSchedule.length, 1);
      final shift = saved.workSchedule.single;
      expect(
        DateTime.parse(
          shift['ends_at'] as String,
        ).difference(DateTime.parse(shift['starts_at'] as String)),
        const Duration(hours: 11),
      );
      expect(c.peopleView.commands.last.payload['work_schedule'], hasLength(1));
      await tester.tap(find.text('Добавить смену'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить смену'));
      await tester.pumpAndSettle();
      expect(
        find.text('Эта смена пересекается с другой сменой работника.'),
        findsOneWidget,
      );
      saved = c.peopleView.person(worker.id)!;
      expect(saved.workSchedule.length, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
