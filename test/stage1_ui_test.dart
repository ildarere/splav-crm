import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/app/stage1_app.dart';
import 'package:splav/core/prototype.dart';
import 'package:splav/features/trips/trip_editor.dart';
import 'package:splav/features/trips/trip_format.dart';
import 'package:splav/features/trips/trips_screen.dart';
import 'package:splav/features/trips/trip_calendar.dart';
import 'package:timezone/data/latest_all.dart' as tz;

const _team = TripTeam(id: 'team', name: 'Команда', role: 'admin');
const _route = TripRoute(id: 'route', teamId: 'team', name: 'Река Медведица');

void main() {
  setUpAll(tz.initializeTimeZones);

  testWidgets(
    'normal launch shows an empty login form without demo credentials',
    (tester) async {
      const channel = MethodChannel('splav/session');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        const Stage1App(
          url: 'http://127.0.0.1:54321',
          anonKey: 'local-public-key',
          profile: 'test',
        ),
      );
      await tester.pumpAndSettle();
      final fields = tester
          .widgetList<TextFormField>(find.byType(TextFormField))
          .toList();
      expect(fields, hasLength(2));
      expect(
        fields.map((field) => field.controller!.text),
        everyElement(isEmpty),
      );
      expect(find.text('Войти'), findsOneWidget);
      expect(calls.map((call) => call.method), ['read']);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    testWidgets(
      'trip list and calendar open a selected trip at width ${size.width}',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = await _controller();
        addTearDown(controller.close);
        await tester.pumpWidget(
          MaterialApp(
            home: TripsScreen(
              allTrips: true,
              controller: controller,
              email: 'organizer@example.com',
              onLogout: () async {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Утренний сплав'), findsOneWidget);
        expect(
          find.byType(DataTable),
          size.width > 900 ? findsOneWidget : findsNothing,
        );
        await tester.tap(find.text('Календарь'));
        await tester.pumpAndSettle();
        expect(find.byType(TripCalendar), findsOneWidget);
        await tester.tap(find.text('Список'));
        await tester.pumpAndSettle();
        final open = size.width > 900
            ? find.text('Утренний сплав')
            : find.text('Открыть').first;
        await tester.ensureVisible(open);
        await tester.pumpAndSettle();
        await tester.tap(open);
        await tester.pumpAndSettle();
        expect(find.text('Обзор'), findsOneWidget);
        expect(find.text('Участники'), findsOneWidget);
        expect(controller.selectedTripId, 'trip-a');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('key actions remain available with 200 percent text scaling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = await _controller();
    addTearDown(controller.close);
    await tester.pumpWidget(
      MaterialApp(
        home: TripsScreen(
          allTrips: true,
          controller: controller,
          email: 'organizer@example.com',
          onLogout: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Создать выезд'), findsOneWidget);
    expect(find.byTooltip('Обновить · F5'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Создать выезд'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Создать выезд'));
    await tester.pumpAndSettle();
    expect(find.byType(TripEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('trip editor rejects a zero limit and keeps the entered draft', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    const TripEditor(teams: [_team], routes: [_route]),
              ),
              child: const Text('Создать'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Создать'));
    await tester.pumpAndSettle();
    final title = find.widgetWithText(TextFormField, 'Название');
    await tester.enterText(title, 'Выезд на выходные');
    final capacity = find.widgetWithText(TextFormField, 'Лимит клиентов');
    await tester.ensureVisible(capacity);
    await tester.enterText(capacity, '0');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Введите число от 1 до 100000'), findsOneWidget);
    expect(
      tester.widget<TextFormField>(title).controller!.text,
      'Выезд на выходные',
    );
    expect(find.byType(TripEditor), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'trip display uses its timezone for an instant across date boundaries',
    () {
      expect(
        tripDate(DateTime.utc(2026, 11, 5, 22, 30), 'Europe/Saratov'),
        '06.11.2026 02:30',
      );
      expect(
        tripDate(DateTime.utc(2026, 11, 5, 22, 30), 'UTC'),
        '05.11.2026 22:30',
      );
    },
  );
}

Future<Stage1Controller> _controller() async {
  final controller = Stage1Controller(
    PrototypeDatabase(NativeDatabase.memory()),
    _UiApi(),
    retryInterval: null,
  );
  await controller.initialize(autoSync: false);
  await controller.sync();
  controller.setOffline(true);
  return controller;
}

class _UiApi implements Stage1Api {
  @override
  Future<void> prepare() async {}
  @override
  Future<TripCatalog> catalog() async => TripCatalog(
    teams: [_team],
    routes: [_route],
    trips: [
      _trip('trip-a', 'Утренний сплав', DateTime.now()),
      _trip(
        'trip-b',
        'Дальняя река',
        DateTime.now().add(const Duration(days: 3)),
      ),
    ],
  );
  Map<String, dynamic> _trip(String id, String title, DateTime date) => {
    'id': id,
    'team_id': _team.id,
    'title': title,
    'route_id': _route.id,
    'route': _route.name,
    'starts_at': date.toUtc().toIso8601String(),
    'ends_at': date.add(const Duration(hours: 6)).toUtc().toIso8601String(),
    'timezone': 'Europe/Saratov',
    'meeting_point': 'Причал',
    'meeting_at': date
        .subtract(const Duration(hours: 1))
        .toUtc()
        .toIso8601String(),
    'responsible_names': 'Инструктор',
    'capacity': 20,
    'base_price_kopeks': 250000,
    'notes': '',
    'status': 'open',
    'metadata_version': 1,
  };
  @override
  PrototypeApi groupApi(String tripId) => throw UnimplementedError();
  @override
  Future<TripRoute> createRoute(RouteCommand command) =>
      throw UnimplementedError();
  @override
  Future<TripSaveResult> saveTrip(TripCommand command) =>
      throw UnimplementedError();
}
