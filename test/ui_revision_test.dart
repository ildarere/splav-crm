import 'dart:io';
import 'dart:ui' as ui;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/app/app_theme.dart';
import 'package:splav/core/prototype.dart';
import 'package:splav/core/trip_dates.dart';
import 'package:splav/features/trips/trips_screen.dart';
import 'package:splav/features/trips/trip_calendar.dart';
import 'package:splav/features/trips/trip_presentation.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'stage1_fixture.dart';

final _now = DateTime.utc(2026, 11, 6, 8);
JsonMap _trip(
  String id,
  int day, {
  int endDay = 0,
  int booked = 4,
  String status = 'open',
}) => {
  ...serverTrip(
    id,
    draft(title: id, capacity: 10, startsAt: DateTime.utc(2026, 11, day, 6)),
  ),
  'ends_at': DateTime.utc(
    2026,
    11,
    endDay == 0 ? day : endDay,
    14,
  ).toIso8601String(),
  'status': status,
  'booked_clients': booked,
  'confirmed_clients': booked,
  'waiting_clients': 0,
  'instructors': 1,
};

class _Api implements Stage1Api {
  final trips = <JsonMap>[];
  bool online = true;
  int calls = 0;
  @override
  Future<void> prepare() async {
    if (!online) throw const SocketException('Offline');
  }

  @override
  Future<TripCatalog> catalog() async {
    calls++;
    return TripCatalog(
      teams: const [TripTeam(id: demoTeam, name: 'Команда', role: 'admin')],
      routes: const [
        TripRoute(id: demoRoute, teamId: demoTeam, name: 'Река Хопёр'),
      ],
      trips: List.of(trips),
    );
  }

  @override
  Future<TripSaveResult> saveTrip(TripCommand command) async {
    final trip = serverTrip(
      command.tripId,
      command.draft,
      version: command.expectedVersion + 1,
    );
    trips.removeWhere((t) => t['id'] == command.tripId);
    trips.add(trip);
    return TripSaveResult(trip: trip);
  }

  @override
  Future<TripRoute> createRoute(RouteCommand command) async => command.route;
  @override
  PrototypeApi groupApi(String id) => _EmptyGroup(id);
}

class _EmptyGroup implements PrototypeApi {
  _EmptyGroup(this.groupId);
  @override
  final String groupId;
  @override
  Future<void> prepare() async {}
  @override
  Future<RegistrationResult> submit(RegistrationCommand command) =>
      throw UnimplementedError();
  @override
  Future<GroupPage> pull(int after) async => GroupPage(
    group: PrototypeGroup(
      id: groupId,
      title: 'Выезд',
      route: 'Река',
      startsAt: _now,
      capacity: 10,
    ),
    changes: [],
    cursor: after,
    hasMore: false,
  );
}

Widget _app(Widget child) => RepaintBoundary(
  key: const ValueKey('preview'),
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: splavTheme(),
    locale: const Locale('ru', 'RU'),
    supportedLocales: const [Locale('ru', 'RU')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: child,
  ),
);

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_UI')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('preview')),
  );
  await tester.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: 1);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('.tools/previews');
    await dir.create(recursive: true);
    await File(
      '${dir.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    img.dispose();
  });
}

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    if (const bool.fromEnvironment('CAPTURE_UI') && Platform.isWindows) {
      final text = FontLoader('Roboto');
      for (final name in ['segoeui.ttf', 'seguisb.ttf', 'segoeuib.ttf']) {
        text.addFont(
          File(
            'C:/Windows/Fonts/$name',
          ).readAsBytes().then(ByteData.sublistView),
        );
      }
      await text.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File(
            '.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await icons.load();
    }
  });
  Future<Stage1Controller> controller(_Api api) async {
    final c = Stage1Controller(
      PrototypeDatabase(NativeDatabase.memory()),
      api,
      retryInterval: null,
    );
    addTearDown(c.close);
    await c.database.cacheCatalog(await api.catalog());
    await c.initialize(autoSync: false);
    return c;
  }

  void screen(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'home is yesterday through a week ahead; all trips remain searchable and filterable',
    (tester) async {
      screen(tester, const Size(1700, 1100));
      final api = _Api()
        ..trips.addAll([
          _trip('Давно завершённый', 4),
          _trip('Вчерашний сплав', 5),
          _trip('Сегодняшний сплав', 6),
          _trip('Завтра', 7, booked: 8),
          _trip('Через неделю', 13, booked: 10),
          _trip('Позже', 14),
          _trip('Уже идёт', 3, endDay: 7, booked: 12),
          _trip('Закрытый сплав', 8, status: 'closed'),
        ]);
      final c = await controller(api);
      await tester.pumpWidget(
        _app(
          TripsScreen(
            controller: c,
            email: 'organizer@example.com',
            onLogout: () async {},
            clock: () => _now,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Вчерашний сплав'), findsOneWidget);
      expect(find.text('Сегодняшний сплав'), findsOneWidget);
      expect(find.text('Через неделю'), findsOneWidget);
      expect(find.text('Уже идёт'), findsOneWidget);
      expect(find.text('Давно завершённый'), findsNothing);
      expect(find.text('Позже'), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Синхронизировать'), findsNothing);
      await _capture(tester, 'home');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Все сплавы'));
      await tester.pumpAndSettle();
      expect(find.text('Давно завершённый'), findsOneWidget);
      expect(find.text('Позже'), findsOneWidget);
      await _capture(tester, 'all-trips');
      await tester.enterText(find.byType(TextField), 'Закрытый');
      await tester.pumpAndSettle();
      expect(find.text('Закрытый сплав'), findsOneWidget);
      expect(find.text('Сегодняшний сплав'), findsNothing);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Запись закрыта').last);
      await tester.pumpAndSettle();
      expect(find.text('Закрытый сплав'), findsOneWidget);
      expect(find.text('Сегодняшний сплав'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('calendar shows real multi-day events in large cells', (
    tester,
  ) async {
    screen(tester, const Size(1700, 1100));
    final api = _Api()
      ..trips.addAll([
        _trip('Сегодняшний сплав', 6),
        _trip('Семейный маршрут', 7, endDay: 9, booked: 8),
      ]);
    final c = await controller(api);
    await tester.pumpWidget(
      _app(
        TripsScreen(
          controller: c,
          email: 'test',
          onLogout: () async {},
          clock: () => _now,
          initialCalendar: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TripCalendar), findsOneWidget);
    final bar = find.textContaining('Семейный маршрут').first;
    expect(
      tester
          .getSize(
            find.ancestor(of: bar, matching: find.byType(Material)).first,
          )
          .width,
      greaterThan(300),
    );
    expect(find.text('Все сплавы'), findsNothing);
    expect(find.textContaining('Сегодняшний сплав'), findsOneWidget);
    expect(find.textContaining('Семейный маршрут'), findsNWidgets(2));
    expect(find.byType(CalendarDatePicker), findsNothing);
    await _capture(tester, 'calendar');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('F5 and pull refresh work without an offline toggle', (
    tester,
  ) async {
    screen(tester, const Size(390, 844));
    final api = _Api()..trips.add(_trip('Сплав', 6));
    final c = await controller(api);
    await tester.pumpWidget(
      _app(
        TripsScreen(
          controller: c,
          email: 'test',
          onLogout: () async {},
          clock: () => _now,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = api.calls;
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pumpAndSettle();
    expect(api.calls, greaterThan(before));
    final again = api.calls;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 420));
    await tester.pumpAndSettle();
    expect(api.calls, greaterThan(again));
    expect(find.byTooltip('Обновить · F5'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'large text on a phone preserves controls and a bounded table page',
    (tester) async {
      screen(tester, const Size(390, 844));
      final api = _Api()
        ..trips.addAll([for (var i = 0; i < 200; i++) _trip('Сплав №$i', 6)]);
      final c = await controller(api);
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: TripsScreen(
                controller: c,
                email: 'test',
                onLogout: () async {},
                clock: () => _now,
                allTrips: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Создать выезд'), findsOneWidget);
      expect(find.text('Сплав №199'), findsNothing);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'phone-large-text');
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('home boundaries, timezone and weekday labels are deterministic', () {
    Trip parse(JsonMap data) => Trip(
      id: data['id'] as String,
      route: 'Река',
      version: 1,
      isDownloaded: false,
      draft: TripDraft.fromJson(data, demoTeam),
    );
    final sunday = parse(_trip('Вс-Пн', 8, endDay: 9));
    expect(weekdayRange(sunday), 'вс–пн');
    expect(inHomeWindow(parse(_trip('13', 13)), _now), isTrue);
    expect(inHomeWindow(parse(_trip('14', 14)), _now), isFalse);
    expect(
      overlapsDays(sunday, DateTime(2026, 11, 9), DateTime(2026, 11, 10)),
      isTrue,
    );
    expect(
      const TripOccupancy(8, 8, 0, 0).label(parse(_trip('x', 6))),
      'Почти заполнен',
    );
    expect(
      const TripOccupancy(12, 12, 0, 0).label(parse(_trip('x', 6))),
      'Сверх лимита +2',
    );
  });
  test(
    'connection loss and return automatically resume the durable queue',
    () async {
      final api = _Api()..online = false;
      final c = Stage1Controller(
        PrototypeDatabase(NativeDatabase.memory()),
        api,
        retryInterval: const Duration(milliseconds: 30),
      );
      addTearDown(c.close);
      await c.database.cacheCatalog(await api.catalog());
      await c.initialize();
      await c.sync();
      expect(c.isOffline, isTrue);
      await c.saveTrip(draft(title: 'Без связи'));
      expect(c.pendingCommandCount, 1);
      api.online = true;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while ((c.isOffline || c.pendingCommandCount != 0) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(c.isOffline, isFalse);
      expect(c.pendingCommandCount, 0);
      expect(c.trips.single.title, 'Без связи');
    },
  );
}
