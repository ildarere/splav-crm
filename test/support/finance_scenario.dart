import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/core/prototype.dart';
import 'package:supabase/supabase.dart';
import 'package:uuid/uuid.dart';

class _LostFinanceReply implements PeopleApi {
  _LostFinanceReply(this.api);
  final PeopleApi api;
  bool drop = true, dropAllocationSnapshot = false, failSnapshot = false;
  final payments = <String>[], allocations = <String>[];
  @override
  Future<JsonMap> catalog() => api.catalog();
  @override
  Future<JsonMap> roster(String id, int revision) async {
    if (failSnapshot) {
      failSnapshot = false;
      throw const SocketException('Snapshot interrupted after acknowledgment');
    }
    return api.roster(id, revision);
  }

  @override
  Future<JsonMap> submit(PeopleCommand c) async {
    final result = await api.submit(c);
    if (c.kind == 'add_payment') {
      payments.add(c.id);
      if (drop) {
        drop = false;
        throw const SocketException('Committed payment reply lost');
      }
    }
    if (c.kind == 'allocate_payment') {
      allocations.add(c.id);
      if (dropAllocationSnapshot) {
        dropAllocationSnapshot = false;
        failSnapshot = true;
      }
    }
    return result;
  }
}

Future<void> financeScenario({
  required String url,
  required String key,
  required Future<PrototypeDatabase> Function(String) openDatabase,
  Future<void> Function(Stage1Controller)? inspect,
}) async {
  const uuid = Uuid();
  final warning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final ca = SupabaseClient(
    url,
    key,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final cb = SupabaseClient(
    url,
    key,
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  Stage1Controller? currentA, currentB;
  try {
    for (final c in [ca, cb]) {
      await c.auth.signInWithPassword(
        email: 'organizer-a@example.com',
        password: 'local-splav-demo-2026',
      );
    }
    final transport = _LostFinanceReply(SupabasePeopleApi(ca));
    Future<Stage1Controller> open(
      String name,
      SupabaseClient client,
      PeopleApi peopleApi,
    ) async {
      final db = await openDatabase(name);
      await db.bindAccountOwner(client.auth.currentUser!.id);
      final c = Stage1Controller(
        db,
        SupabaseStage1Api(client: client, prepare: () async {}),
        peopleApi: peopleApi,
        retryInterval: null,
      );
      await c.initialize(autoSync: false);
      return c;
    }

    var a = await open('a', ca, transport);
    currentA = a;
    final b = await open('b', cb, SupabasePeopleApi(cb));
    currentB = b;
    await a.sync();
    expect(a.error, isNull);
    a.setOffline(true);
    final team = a.teams.firstWhere((t) => t.canCreate), route = a.routes.first;
    final trip = await a.saveTrip(
      TripDraft(
        teamId: team.id,
        title: 'Семейная оплата ${uuid.v4()}',
        routeId: route.id,
        startsAt: DateTime.utc(2036, 8, 1, 5),
        endsAt: DateTime.utc(2036, 8, 2, 14),
        timeZone: 'Europe/Saratov',
        meetingAt: DateTime.utc(2036, 8, 1, 4, 30),
        meetingPoint: 'Причал',
        responsibleNames: 'Организатор',
        capacity: 3,
        basePriceKopecks: 100000,
        notes: 'Вымышленные денежные операции',
        status: 'open',
      ),
    );
    a.setOffline(false);
    await a.sync();
    expect(a.error, isNull);
    expect(a.financeView.ready, isTrue);
    await b.sync();
    await b.chooseTrip(trip);
    await b.sync();
    expect(b.financeView.ready, isTrue);
    final people = [
      for (var i = 0; i < 3; i++)
        <String, dynamic>{
          'id': uuid.v4(),
          'name': 'Семья $i ${uuid.v4()}',
          'phone': '',
          'archived': false,
        },
    ];
    final ids = [for (var i = 0; i < 3; i++) uuid.v4()];
    a.setOffline(true);
    await a.saveBooking({
      'contact_name': 'Семейная заявка',
      'members': [
        for (var i = 0; i < 3; i++)
          {
            'id': ids[i],
            'person_id': people[i]['id'],
            'role': 'client',
            'parameters': <String, dynamic>{},
          },
      ],
    }, newPeople: people);
    final booking = a.peopleView.bookings.single.id;
    await a.queueFinance('set_prices', {
      'booking_id': booking,
      'reason': 'Согласовано',
      'lines': [
        for (final p in a.peopleView.participations)
          {'id': p.id, 'version': p.version, 'amount_kopeks': 100000},
      ],
    });
    List<JsonMap> lines(int x, int y, int z) => [
      for (var i = 0; i < 3; i++)
        if ([x, y, z][i] > 0)
          {
            'participation_id': ids[i],
            'amount_kopeks': [x, y, z][i],
          },
    ];
    JsonMap payment(
      int amount,
      List<JsonMap> allocation, {
      String direction = 'income',
    }) => {
      'booking_id': booking,
      'amount_kopeks': amount,
      'allocations': allocation,
      'direction': direction,
      'method': 'transfer',
      'occurred_at': DateTime.utc(2036, 7, 1, 8, 30).toIso8601String(),
      'notes': 'Семейная оплата',
    };
    await a.queueFinance(
      'add_payment',
      payment(250000, lines(100000, 100000, 50000)),
    );
    expect(a.financeView.net(booking), 250000);
    expect(a.peopleView.commands, hasLength(6));
    await a.close();
    a = await open('a', ca, transport);
    currentA = a;
    a.setOffline(true);
    await a.chooseTrip(trip);
    expect(a.financeView.provisional, isTrue);
    expect(a.financeView.net(booking), 250000);
    a.setOffline(false);
    await a.sync();
    expect(a.error, isNotNull);
    expect(transport.payments, hasLength(1));
    await a.close();
    a = await open('a', ca, transport);
    currentA = a;
    await a.chooseTrip(trip);
    await a.sync();
    expect(a.error, isNull);
    expect(a.financeView.commands, isEmpty);
    expect(a.financeView.payments, hasLength(1));
    expect(transport.payments, [
      transport.payments.first,
      transport.payments.first,
    ]);
    expect(a.financeView.net(booking), 250000);
    expect(a.financeView.credited(ids[2]), 50000);
    await b.sync();
    a.setOffline(true);
    b.setOffline(true);
    await a.queueFinance('add_payment', payment(10000, []));
    await b.queueFinance('add_payment', payment(10000, []));
    a.setOffline(false);
    b.setOffline(false);
    await Future.wait([a.sync(), b.sync()]);
    await Future.wait([a.sync(), b.sync()]);
    expect(a.financeView.net(booking), 270000);
    expect(b.financeView.net(booking), 270000);
    expect(a.financeView.unallocated(booking), 20000);
    await a.queueFinance(
      'add_payment',
      payment(20000, [], direction: 'refund'),
    );
    await a.sync();
    expect(a.error, isNull);
    expect(a.financeView.net(booking), 250000);
    final original = a.financeView.payments.firstWhere(
      (p) => p.direction == 'income' && p.amount == 250000,
    );
    transport.dropAllocationSnapshot = true;
    await a.queueFinance('allocate_payment', {
      'booking_id': booking,
      'id': original.id,
      'reason': 'Уточнение распределения',
      'allocations': lines(100000, 100000, 50000),
    }, expectedVersion: original.version);
    await a.sync();
    expect(a.error, isNotNull);
    expect(a.financeView.commands.single.ackRevision, isNotNull);
    await a.close();
    a = await open('a', ca, transport);
    currentA = a;
    await a.chooseTrip(trip);
    await a.sync();
    expect(a.error, isNull);
    expect(a.financeView.commands, isEmpty);
    expect(transport.allocations, hasLength(1));
    final updated = a.financeView.payments.firstWhere(
      (p) => p.id == original.id,
    );
    await a.queueFinance('correct_payment', {
      'booking_id': booking,
      'id': updated.id,
      'reason': 'Исправлена сумма',
      'replacement': payment(240000, lines(100000, 100000, 40000)),
    }, expectedVersion: updated.version);
    await a.sync();
    expect(a.error, isNull);
    expect(a.financeView.net(booking), 240000);
    expect(a.financeView.reversed(original.id), isTrue);
    expect(a.financeView.payments, hasLength(6));
    await b.sync();
    expect(b.financeView.net(booking), 240000);
    expect(a.financeView.credited(ids[2]), 40000);
    a.setOffline(true);
    await a.close();
    a = await open('a', ca, transport);
    currentA = a;
    a.setOffline(true);
    await a.chooseTrip(trip);
    expect(a.financeView.net(booking), 240000);
    expect(a.financeView.priceHistory, hasLength(3));
    if (inspect != null) await inspect(a);
  } finally {
    await currentA?.clearAccountData();
    await currentB?.clearAccountData();
    await currentA?.close();
    await currentB?.close();
    await ca.dispose();
    await cb.dispose();
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = warning;
  }
}
