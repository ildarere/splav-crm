import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/core/prototype.dart';
import 'package:splav/app/app_theme.dart';
import 'package:splav/features/payments/finance_screen.dart';
import 'package:splav/features/bookings/roster_screen.dart';
import 'package:splav/app/sync_widgets.dart';
import 'support/ui_preview.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'stage1_fixture.dart';

class _Stage implements Stage1Api {
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

class _People implements PeopleApi {
  @override
  Future<JsonMap> catalog() => throw UnimplementedError();
  @override
  Future<JsonMap> roster(String id, int revision) => throw UnimplementedError();
  @override
  Future<JsonMap> submit(PeopleCommand c) => throw UnimplementedError();
}

void main() {
  setUpAll(() async {
    tz.initializeTimeZones();
    await loadPreviewFonts();
  });
  Future<Stage1Controller> fixture({
    List<int> credited = const [100000, 100000, 50000],
    int unallocated = 0,
  }) async {
    final c = Stage1Controller(
      PrototypeDatabase(NativeDatabase.memory()),
      _Stage(),
      peopleApi: _People(),
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
      'price_history': [],
      'allocation_history': [],
      'people': [
        for (var i = 0; i < 3; i++)
          {
            'id': 'person$i',
            'team_id': demoTeam,
            'name': ['Первый', 'Второй', 'Ребёнок'][i],
            'version': 1,
          },
      ],
      'bookings': [
        {
          'id': 'booking',
          'trip_id': demoGroup,
          'contact_name': 'Семья',
          'version': 1,
        },
      ],
      'participations': [
        for (var i = 0; i < 3; i++)
          {
            'id': 'p$i',
            'person_id': 'person$i',
            'booking_id': 'booking',
            'trip_id': demoGroup,
            'role': 'client',
            'status': 'confirmed',
            'version': 1,
            'agreed_price_kopeks': 100000,
            'parameters': <String, dynamic>{
              if (i == 0) 'height_cm': 180,
              if (i == 0) 'weight_kg': 80,
              if (i == 2) 'age_years': 12,
              if (i == 2) 'food_notes': 'Без орехов',
            },
          },
      ],
      'payments': [
        if (credited.any((v) => v > 0) || unallocated > 0)
          {
            'id': 'payment',
            'booking_id': 'booking',
            'signed_kopeks':
                credited.fold<int>(0, (a, b) => a + b) + unallocated,
            'direction': 'income',
            'method': 'transfer',
            'version': 1,
            'occurred_at': '2026-11-06T08:00:00Z',
            'allocations': [
              for (var i = 0; i < 3; i++)
                if (credited[i] > 0)
                  {'participation_id': 'p$i', 'amount_kopeks': credited[i]},
            ],
          },
      ],
    });
    await c.initialize(autoSync: false);
    c.setOffline(true);
    return c;
  }

  Widget app(Stage1Controller c, {bool roster = false}) => RepaintBoundary(
    key: const ValueKey('preview'),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: splavTheme(),
      locale: const Locale('ru', 'RU'),
      supportedLocales: const [Locale('ru', 'RU')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: DefaultTabController(
        length: 3,
        child: Builder(
          builder: (context) => Scaffold(
            appBar: roster
                ? AppBar(
                    toolbarHeight: syncToolbarHeight(context),
                    title: SyncPageTitle(title: 'Участники', controller: c),
                  )
                : null,
            body: roster
                ? RosterScreen(controller: c)
                : FinanceScreen(controller: c),
          ),
        ),
      ),
    ),
  );

  void viewport(WidgetTester tester, [Size size = const Size(1440, 1100)]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'payment filters preserve full company totals and header sync status',
    (tester) async {
      viewport(tester);
      final c = await fixture(credited: [0, 20000, 100000]);
      await tester.pumpWidget(app(c, roster: true));
      await tester.pumpAndSettle();
      expect(find.text('Первый'), findsOneWidget);
      expect(find.text('Второй'), findsOneWidget);
      expect(find.text('Ребёнок'), findsOneWidget);
      expect(find.text('Семья · 3 чел.'), findsOneWidget);
      expect(find.text('3 000 ₽'), findsOneWidget);
      expect(find.text('1 200 ₽'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.textContaining('Без сети'),
          matching: find.byType(AppBar),
        ),
        findsOneWidget,
      );
      await captureUi(tester, 'participants-desktop');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Есть предоплата'));
      await tester.pumpAndSettle();
      expect(find.text('Первый'), findsNothing);
      expect(find.text('Второй'), findsOneWidget);
      expect(find.text('Ребёнок'), findsNothing);
      expect(find.text('Семья · 3 чел.'), findsOneWidget);
      expect(find.text('3 000 ₽'), findsOneWidget);
      expect(find.text('1 200 ₽'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Нет предоплаты'));
      await tester.pumpAndSettle();
      expect(find.text('Первый'), findsOneWidget);
      expect(find.text('Второй'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Оплачено полностью'));
      await tester.pumpAndSettle();
      expect(find.text('Ребёнок'), findsOneWidget);
      expect(find.text('Первый'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'company deposit allocates 500 per person in one durable command',
    (tester) async {
      viewport(tester);
      final c = await fixture(credited: [0, 0, 0]);
      await tester.pumpWidget(app(c, roster: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Предоплата · 500 ₽/чел.'));
      await tester.pumpAndSettle();
      final amount = find.widgetWithText(TextFormField, 'Сумма, ₽');
      expect(tester.widget<TextFormField>(amount).controller!.text, '1500,00');
      await tester.tap(find.text('Кому зачесть оплату'));
      await tester.pumpAndSettle();
      for (final name in ['Первый', 'Второй', 'Ребёнок']) {
        expect(
          tester
              .widget<TextFormField>(find.widgetWithText(TextFormField, name))
              .controller!
              .text,
          '500,00',
        );
      }
      await captureUi(tester, 'company-deposit');
      await tester.tap(find.text('Сохранить платёж'));
      await tester.pumpAndSettle();
      final command = c.financeView.commands.single;
      expect(command.payload['amount_kopeks'], 150000);
      expect(command.payload['allocations'], hasLength(3));
      expect(c.financeView.net('booking'), 150000);
      expect(participantCredits(c.financeView), {
        'p0': 50000,
        'p1': 50000,
        'p2': 50000,
      });
      expect(await c.database.serverRoster(demoGroup), isNotNull);
      final depositButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Предоплата · 500 ₽/чел.'),
      );
      expect(depositButton.onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unallocated money is shown and quick collection waits for allocation',
    (tester) async {
      viewport(tester);
      final c = await fixture(credited: [0, 0, 0], unallocated: 50000);
      await tester.pumpWidget(app(c, roster: true));
      await tester.pumpAndSettle();
      expect(find.text('Не распределено'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Предоплата · 500 ₽/чел.'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Оплатить остаток'),
            )
            .onPressed,
        isNull,
      );
      expect(find.widgetWithText(OutlinedButton, '500 ₽'), findsNothing);
      await tester.tap(find.text('Своя сумма'));
      await tester.pumpAndSettle();
      expect(find.text('Сохранить платёж'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'revocation closes the roster quick-payment form without retaining amounts',
    (tester) async {
      viewport(tester);
      final c = await fixture(credited: [0, 0, 0]);
      await tester.pumpWidget(app(c, roster: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Предоплата · 500 ₽/чел.'));
      await tester.pumpAndSettle();
      await c.database.cacheCatalog(
        const TripCatalog(teams: [], routes: [], trips: []),
      );
      await c.initialize(autoSync: false);
      await tester.pumpAndSettle();
      expect(find.text('Сохранить платёж'), findsNothing);
      expect(c.financeView.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'personal quick payment allows a precise custom amount and remaining payment',
    (tester) async {
      viewport(tester);
      final c = await fixture(credited: [0, 20000, 100000]);
      await tester.pumpWidget(app(c, roster: true));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, '500 ₽').first);
      await tester.pumpAndSettle();
      final amount = find.widgetWithText(TextFormField, 'Сумма, ₽');
      expect(tester.widget<TextFormField>(amount).controller!.text, '500,00');
      await tester.enterText(amount, '375,25');
      await tester.tap(find.text('Сохранить платёж'));
      await tester.pumpAndSettle();
      expect(c.financeView.commands.single.payload['allocations'], [
        {'participation_id': 'p0', 'amount_kopeks': 37525},
      ]);
      expect(c.financeView.credited('p0'), 37525);
      expect(c.financeView.credited('p1'), 20000);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Оплатить').first);
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(amount).controller!.text, '624,75');
      await tester.tap(find.text('Сохранить платёж'));
      await tester.pumpAndSettle();
      expect(c.financeView.credited('p0'), 100000);
      expect(c.financeView.commands, hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('roster and quick payment fit a phone at 200 percent text', (
    tester,
  ) async {
    viewport(tester, const Size(390, 844));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final c = await fixture(credited: [0, 0, 0]);
    await tester.pumpWidget(app(c, roster: true));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Предоплата · 500 ₽/чел.'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await captureUi(tester, 'participants-phone-200');
    await tester.tap(find.text('Предоплата · 500 ₽/чел.'));
    await tester.pumpAndSettle();
    expect(find.text('Предоплата компании'), findsOneWidget);
    expect(find.text('Сохранить платёж'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'deposit balances include previous credits, returns and inexpensive participation',
    () {
      expect(const ParticipantBalance(100000, 20000).depositDue, 30000);
      expect(const ParticipantBalance(100000, 50000).depositDue, 0);
      expect(const ParticipantBalance(30000, 0).depositDue, 30000);
      expect(const ParticipantBalance(0, 0).state, 'free');
      expect(const ParticipantBalance(100000, 100001).state, 'full');
      expect(const ParticipantBalance(100000, 20000).deposit, 20000);
    },
  );
  test(
    'money is parsed as exact integer kopeks and ledger allocations do not double cash',
    () {
      expect(parseKopeks('1 234,56'), 123456);
      expect(parseKopeks('0,01'), 1);
      expect(parseKopeks('1.999'), isNull);
      expect(parseKopeks('-1'), isNull);
      expect(parseKopeks('NaN'), isNull);
      expect(moneyText(-1), '−0,01 ₽');
      final f = FinanceView.project({
        'finance_protocol': 1,
        'payments': [
          {
            'id': 'one',
            'booking_id': 'b',
            'signed_kopeks': 300000,
            'direction': 'income',
            'allocations': [
              for (var i = 0; i < 3; i++)
                {'participation_id': '$i', 'amount_kopeks': 100000},
            ],
          },
          {
            'id': 'return',
            'booking_id': 'b',
            'signed_kopeks': -10000,
            'direction': 'refund',
            'allocations': [
              {'participation_id': '0', 'amount_kopeks': 10000},
            ],
          },
        ],
      }, []);
      expect(f.net('b'), 290000);
      expect(f.received('b'), 300000);
      expect(f.refunded('b'), 10000);
      expect(f.credited('0'), 90000);
      expect(f.unallocated('b'), 0);
    },
  );
  testWidgets(
    'a family payment displays once; a partial amount retains exact cents offline',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await fixture();
      await tester.pumpWidget(app(c));
      await tester.pumpAndSettle();
      expect(c.financeView.net('booking'), 250000);
      expect(find.text('Остаток 500,00 ₽'), findsOneWidget);
      await tester.tap(find.text('Получить оплату'));
      await tester.pumpAndSettle();
      final amount = find.widgetWithText(TextFormField, 'Сумма, ₽');
      await tester.enterText(amount, '1,999');
      await tester.tap(find.text('Сохранить платёж'));
      await tester.pumpAndSettle();
      expect(c.financeView.commands, isEmpty);
      await tester.enterText(amount, '500,01');
      await tester.tap(find.text('Сохранить платёж'));
      await tester.pumpAndSettle();
      expect(c.financeView.net('booking'), 300001);
      expect(c.financeView.provisional, isTrue);
      expect(c.financeView.commands.single.payload['amount_kopeks'], 50001);
      expect(find.textContaining('Предварительные суммы'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'a correction requires a reason and preserves the original payment',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await fixture();
      await tester.pumpWidget(app(c));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Исправить с причиной'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Исправить с причиной'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить корректировку'));
      await tester.pumpAndSettle();
      expect(find.text('Укажите причину для истории'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Сумма, ₽'),
        '2400',
      );
      await tester.ensureVisible(find.text('Кому зачесть оплату'));
      await tester.tap(find.text('Кому зачесть оплату'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(TextFormField, 'Ребёнок'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Ребёнок'),
        '400',
      );
      await tester.ensureVisible(
        find.widgetWithText(TextFormField, 'Причина изменения'),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Причина изменения'),
        'Ошибка суммы',
      );
      await tester.tap(find.text('Сохранить корректировку'));
      await tester.pumpAndSettle();
      expect(c.financeView.payments, hasLength(3));
      expect(c.financeView.reversed('payment'), isTrue);
      expect(c.financeView.net('booking'), 240000);
      expect(
        (await c.database.serverRoster(demoGroup))!['payments'],
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('revoked trip closes an already open financial form', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await fixture();
    await tester.pumpWidget(app(c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Получить оплату'));
    await tester.pumpAndSettle();
    expect(find.text('Сохранить платёж'), findsOneWidget);
    await c.database.cacheCatalog(
      const TripCatalog(teams: [], routes: [], trips: []),
    );
    await c.initialize(autoSync: false);
    await tester.pumpAndSettle();
    expect(find.text('Сохранить платёж'), findsNothing);
    expect(c.financeView.payments, isEmpty);
    expect(c.financeView.commands, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'financial actions remain usable on a phone at 200 percent text',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final c = await fixture();
      await tester.pumpWidget(app(c));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Получить оплату'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Получить оплату'));
      await tester.pumpAndSettle();
      expect(find.text('Сохранить платёж'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
