import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/core/prototype.dart';
import 'package:splav/core/vest_sizes.dart';
import 'package:splav/features/payments/payment_editor.dart';
import 'package:splav/features/people/person_editor.dart';
import 'package:splav/features/kayaks/kayaks_screen.dart';
import 'package:splav/features/transport/transport_screen.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'stage1_fixture.dart';

class Api implements Stage1Api {
  @override
  Future<void> prepare() async {}
  @override
  Future<TripCatalog> catalog() => throw UnimplementedError();
  @override
  Future<TripSaveResult> saveTrip(TripCommand c) => throw UnimplementedError();
  @override
  Future<TripRoute> createRoute(RouteCommand c) => throw UnimplementedError();
  @override
  PrototypeApi groupApi(String id) => throw UnimplementedError();
}

class People implements PeopleApi {
  @override
  Future<JsonMap> catalog() => throw UnimplementedError();
  @override
  Future<JsonMap> roster(String id, int rev) => throw UnimplementedError();
  @override
  Future<JsonMap> submit(PeopleCommand c) => throw UnimplementedError();
}

void main() {
  setUpAll(tz.initializeTimeZones);
  Future<Stage1Controller> fixture() async {
    final c = Stage1Controller(
      PrototypeDatabase(NativeDatabase.memory()),
      Api(),
      peopleApi: People(),
      retryInterval: null,
    );
    addTearDown(c.close);
    await c.database.cacheCatalog(
      TripCatalog(
        teams: const [TripTeam(id: demoTeam, name: 'Команда', role: 'admin')],
        routes: const [
          TripRoute(id: demoRoute, teamId: demoTeam, name: 'Река'),
        ],
        trips: [serverTrip(demoGroup, draft())],
      ),
    );
    await c.database.cacheRoster({
      'trip_id': demoGroup,
      'team_id': demoTeam,
      'revision': 1,
      'finance_protocol': 1,
      'payments': [],
      'price_history': [],
      'allocation_history': [],
      'people': [
        for (var i = 1; i <= 2; i++)
          {
            'id': 'person$i',
            'team_id': demoTeam,
            'name': 'Человек $i',
            'version': 1,
          },
      ],
      'bookings': [
        {
          'id': 'company',
          'trip_id': demoGroup,
          'contact_name': 'Компания',
          'version': 1,
        },
      ],
      'participations': [
        for (var i = 1; i <= 2; i++)
          {
            'id': 'r$i',
            'trip_id': demoGroup,
            'person_id': 'person$i',
            'booking_id': 'company',
            'role': 'client',
            'status': 'confirmed',
            'parameters': {},
            'agreed_price_kopeks': 700000,
            'version': 1,
          },
      ],
      'operations_protocol': 1,
      'operations': {
        'resources': [
          {
            'id': 'boat',
            'kind': 'boat',
            'model': 'big',
            'name': 'Байдарка',
            'capacity': 3,
            'available': true,
          },
        ],
        'reservations': [
          {
            'id': 'reservation',
            'kind': 'boat',
            'resource_id': 'boat',
            'capacity': 3,
            'active': true,
            'version': 1,
          },
        ],
        'crews': [
          for (var i = 1; i <= 2; i++)
            {
              'registration_id': 'r$i',
              'reservation_id': 'reservation',
              'seat': i,
              'version': 1,
            },
        ],
      },
    });
    await c.initialize(autoSync: false);
    c.setOffline(true);
    return c;
  }

  test(
    'Vest size aliases share the same bucket without merging ambiguous ranges',
    () {
      for (final s in [
        'M',
        'М',
        '48',
        '50р',
        '48 р',
        'размер 50',
        '48–50',
        '48/50',
      ]) {
        expect(vestSize(s), 'M', reason: s);
      }
      expect(vestSize('ХL'), 'XL');
      expect(vestSize('2XL'), 'XXL');
      expect(vestSize('46-48'), '46-48');
      expect(vestSize(null), 'Не указан');
    },
  );
  for (final mode in [PaymentMode.income, PaymentMode.refund]) {
    testWidgets('Payment $mode fixes direction and hides allocation details', (
      tester,
    ) async {
      final c = await fixture();
      JsonMap? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<JsonMap>(
                    context: context,
                    builder: (_) => PaymentEditor(
                      controller: c,
                      booking: c.peopleView.bookings.first,
                      mode: mode,
                      initialAllocations: const {'r1': 50000},
                    ),
                  );
                },
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      expect(find.text('Направление'), findsNothing);
      expect(find.text('Способ'), findsNothing);
      expect(find.byType(ExpansionTile), findsOneWidget);
      expect(
        tester
            .widget<ExpansionTile>(find.byType(ExpansionTile))
            .initiallyExpanded,
        isFalse,
      );
      await tester.tap(find.text('Сохранить платёж'));
      await tester.pumpAndSettle();
      expect(
        result?['payload']['direction'],
        mode == PaymentMode.refund ? 'refund' : 'income',
      );
      expect(result?['payload']['method'], 'other');
      expect(result?['payload']['allocations'].length, 1);
    });
  }
  testWidgets('New person hides team and saves inline parameters', (
    tester,
  ) async {
    JsonMap? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<JsonMap>(
                  context: context,
                  builder: (_) => const PersonEditor(
                    teams: [
                      TripTeam(id: demoTeam, name: 'A', role: 'admin'),
                      TripTeam(id: 'other', name: 'B', role: 'admin'),
                    ],
                    people: [],
                  ),
                );
              },
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Имя и фамилия *'),
      'Новый человек',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Размер жилета'),
      '50',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Рост, см'),
      '180',
    );
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(result?['parameters'], {'clothing_size': 'M', 'height_cm': 180});
    expect(result?['team_id'], demoTeam);
  });
  testWidgets('Dragging onto an occupied kayak seat swaps both participants', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await fixture();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: KayaksScreen(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    final from = tester.getCenter(find.text('Человек 1'));
    final to = tester.getCenter(find.text('Человек 2'));
    await tester.dragFrom(from, to - from);
    await tester.pumpAndSettle();
    expect(c.operationsView.crew('r1')?['seat'], 2);
    expect(c.operationsView.crew('r2')?['seat'], 1);
    final cmd = c.peopleView.commands.where((c) => c.kind == 'ops_crew').single;
    expect(cmd.payload['swap_id'], 'r2');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Quick instructor creates a separate zero-price record without taking a client seat',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await fixture();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: KayaksScreen(controller: c)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Добавить инструктора'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Новый инструктор'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Имя и фамилия *'),
        'Новый инструктор',
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      final p = c.peopleView.participations
          .where((p) => p.role == 'instructor')
          .single;
      expect(p.priceKopecks, 0);
      expect(c.operationsView.crew(p.id), isNull);
      expect(c.operationsView.crew('r1')?['seat'], 1);
      expect(c.operationsView.crew('r2')?['seat'], 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Overflow offers a bus selector with a new bus action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await fixture();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TransportScreen(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить автобус · 2 без места'));
    await tester.pumpAndSettle();
    expect(find.text('Следующий автобус'), findsOneWidget);
    expect(find.text('Новый автобус'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
