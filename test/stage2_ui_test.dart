import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/core/prototype.dart';
import 'package:splav/features/bookings/booking_editor.dart';
import 'package:splav/features/bookings/roster_screen.dart';
import 'package:splav/features/people/person_editor.dart';
import 'package:splav/features/trips/trips_screen.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'stage1_fixture.dart';

class _UnusedStage1Api implements Stage1Api {
  @override
  Future<void> prepare() async {}
  @override
  Future<TripCatalog> catalog() async => throw UnimplementedError();
  @override
  Future<TripSaveResult> saveTrip(TripCommand command) =>
      throw UnimplementedError();
  @override
  Future<TripRoute> createRoute(RouteCommand command) =>
      throw UnimplementedError();
  @override
  PrototypeApi groupApi(String tripId) => throw UnimplementedError();
}

class _UnusedPeopleApi implements PeopleApi {
  @override
  Future<JsonMap> catalog() => throw UnimplementedError();
  @override
  Future<JsonMap> roster(String tripId, int revision) =>
      throw UnimplementedError();
  @override
  Future<JsonMap> submit(PeopleCommand command) => throw UnimplementedError();
}

const _team = TripTeam(id: demoTeam, name: 'Команда', role: 'admin');
const _route = TripRoute(id: demoRoute, teamId: demoTeam, name: 'Река Хопёр');

Widget app(Widget child) => MaterialApp(
  locale: const Locale('ru', 'RU'),
  supportedLocales: const [Locale('ru', 'RU')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  theme: ThemeData(
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
    ),
  ),
  home: child,
);

void main() {
  setUpAll(tz.initializeTimeZones);
  testWidgets('booking actions remain accessible on a phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = Stage1Controller(
      PrototypeDatabase(NativeDatabase.memory()),
      _UnusedStage1Api(),
      peopleApi: _UnusedPeopleApi(),
      retryInterval: null,
    );
    addTearDown(controller.close);
    await controller.database.cacheCatalog(
      TripCatalog(
        teams: [_team],
        routes: [_route],
        trips: [serverTrip('trip', draft())],
      ),
    );
    await controller.database.cacheRoster({
      'trip_id': 'trip',
      'team_id': demoTeam,
      'revision': 0,
      'bookings': [],
      'participations': [],
      'people': [],
    });
    await controller.initialize(autoSync: false);
    controller.setOffline(true);
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: Scaffold(body: RosterScreen(controller: controller)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Новая компания'));
    await tester.tap(find.text('Новая компания'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Новый участник'));
    expect(tester.takeException(), isNull);
    expect(find.text('Сохранить компанию'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'trip fields keep gaps and the desktop table fills available width',
    (tester) async {
      tester.view.physicalSize = const Size(1800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = Stage1Controller(
        PrototypeDatabase(NativeDatabase.memory()),
        _UnusedStage1Api(),
        retryInterval: null,
      );
      addTearDown(controller.close);
      await controller.database.cacheCatalog(
        TripCatalog(
          teams: [_team],
          routes: [_route],
          trips: [serverTrip('trip', draft())],
        ),
      );
      await controller.initialize(autoSync: false);
      controller.setOffline(true);
      await tester.pumpWidget(
        app(
          TripsScreen(
            allTrips: true,
            controller: controller,
            email: 'test@example.com',
            onLogout: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(DataTable)).width,
        greaterThanOrEqualTo(1752),
      );
      await tester.tap(find.text('Создать выезд'));
      await tester.pumpAndSettle();
      final capacity = find.widgetWithText(TextFormField, 'Лимит клиентов');
      final price = find.widgetWithText(TextFormField, 'Базовая стоимость, ₽');
      final status = find.widgetWithText(
        DropdownButtonFormField<String>,
        'Статус',
      );
      final notes = find.widgetWithText(TextFormField, 'Примечание');
      expect(
        tester.getTopLeft(price).dy - tester.getBottomLeft(capacity).dy,
        greaterThanOrEqualTo(12),
      );
      expect(
        tester.getTopLeft(status).dy - tester.getBottomLeft(price).dy,
        greaterThanOrEqualTo(12),
      );
      expect(
        tester.getTopLeft(notes).dy - tester.getBottomLeft(status).dy,
        greaterThanOrEqualTo(12),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a shared phone warns about duplicates and allows a distinct family member',
    (tester) async {
      final existing = PersonCard({
        'id': 'parent',
        'team_id': demoTeam,
        'name': 'Родитель',
        'phone': '+7 900 111-22-33',
        'version': 1,
      });
      JsonMap? saved;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showDialog<JsonMap>(
                    context: context,
                    builder: (_) =>
                        PersonEditor(teams: [_team], people: [existing]),
                  );
                },
                child: const Text('Новый человек'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Новый человек'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Имя и фамилия'),
        'Другой член семьи',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Телефон'),
        '8 (900) 111-22-33',
      );
      await tester.pumpAndSettle();
      expect(find.text('Есть похожие карточки'), findsOneWidget);
      await tester.ensureVisible(find.text('Проверено, это другой человек'));
      await tester.tap(find.text('Проверено, это другой человек'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
      await tester.pumpAndSettle();
      expect(saved?['name'], 'Другой член семьи');
      expect(saved?['phone'], '8 (900) 111-22-33');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'one offline form creates a family with three individual participations',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = Stage1Controller(
        PrototypeDatabase(NativeDatabase.memory()),
        _UnusedStage1Api(),
        peopleApi: _UnusedPeopleApi(),
        retryInterval: null,
      );
      addTearDown(controller.close);
      await controller.database.cacheCatalog(
        TripCatalog(
          teams: [_team],
          routes: [_route],
          trips: [serverTrip('trip', draft())],
        ),
      );
      await controller.database.cacheRoster({
        'trip_id': 'trip',
        'team_id': demoTeam,
        'revision': 0,
        'bookings': [],
        'participations': [],
        'people': [],
      });
      await controller.initialize(autoSync: false);
      controller.setOffline(true);
      await tester.pumpWidget(
        app(Scaffold(body: RosterScreen(controller: controller))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Новая компания'));
      await tester.pumpAndSettle();
      for (final name in ['Первый взрослый', 'Второй взрослый', 'Ребёнок']) {
        await tester.ensureVisible(find.text('Новый участник'));
        await tester.tap(find.text('Новый участник'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Имя и фамилия'),
          name,
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Сохранить компанию'));
      await tester.pumpAndSettle();
      expect(find.byType(BookingEditor), findsNothing);
      final commands = await controller.database.peopleCommands();
      expect(commands.where((c) => c.kind == 'save_person'), hasLength(3));
      expect(commands.where((c) => c.kind == 'save_booking'), hasLength(1));
      expect(controller.peopleView.participations, hasLength(3));
      expect(controller.peopleView.confirmedCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
