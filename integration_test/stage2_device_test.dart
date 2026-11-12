import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:splav/core/prototype.dart';
import 'package:splav/features/bookings/roster_screen.dart';
import 'package:supabase/supabase.dart';
import 'package:uuid/uuid.dart';
import 'package:timezone/data/latest_all.dart' as tz;

class _LostReply implements PeopleApi {
  _LostReply(this.api);
  final PeopleApi api;
  bool lose = true;
  final sent = <String>[];
  @override
  Future<JsonMap> catalog() => api.catalog();
  @override
  Future<JsonMap> roster(String id, int revision) => api.roster(id, revision);
  @override
  Future<JsonMap> submit(PeopleCommand command) async {
    final result = await api.submit(command);
    if (command.kind == 'save_booking') {
      sent.add(command.id);
      if (lose) {
        lose = false;
        throw const SocketException('Committed response lost');
      }
    }
    return result;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_ANON_KEY');
  testWidgets(
    'native family, durable offline queue, lost reply and two-client final seat',
    (tester) async {
      const uuid = Uuid();
      final previousWarning =
          driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(
        () => driftRuntimeOptions.dontWarnAboutMultipleDatabases =
            previousWarning,
      );
      SupabaseClient client() {
        final result = SupabaseClient(
          url,
          key,
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        addTearDown(result.dispose);
        return result;
      }

      final clientA = client(), clientB = client();
      for (final c in [clientA, clientB]) {
        await c.auth.signInWithPassword(
          email: 'organizer-a@example.com',
          password: 'local-splav-demo-2026',
        );
      }
      final transport = _LostReply(SupabasePeopleApi(clientA));
      final scope = 'stage2-device-${uuid.v4()}';
      Future<Stage1Controller> open(
        String profile,
        SupabaseClient c,
        PeopleApi api,
      ) async {
        final db = await PrototypeDatabase.open(scope: '$scope-$profile');
        await db.bindAccountOwner(c.auth.currentUser!.id);
        final controller = Stage1Controller(
          db,
          SupabaseStage1Api(client: c, prepare: () async {}),
          peopleApi: api,
          retryInterval: null,
        );
        await controller.initialize(autoSync: false);
        return controller;
      }

      var a = await open('a', clientA, transport);
      final b = await open('b', clientB, SupabasePeopleApi(clientB));
      try {
        await a.sync();
        expect(a.error, isNull);
        final team = a.teams.firstWhere((t) => t.canCreate),
            route = a.routes.first;
        a.setOffline(true);
        final trip = await a.saveTrip(
          TripDraft(
            teamId: team.id,
            routeId: route.id,
            title: 'Проверка семьи на устройстве ${uuid.v4()}',
            startsAt: DateTime.utc(2034, 8, 1, 5),
            endsAt: DateTime.utc(2034, 8, 2, 14),
            timeZone: 'Europe/Saratov',
            meetingAt: DateTime.utc(2034, 8, 1, 4, 30),
            meetingPoint: 'Причал',
            responsibleNames: 'Организатор',
            capacity: 2,
            basePriceKopecks: 700000,
            notes: 'Вымышленные данные',
            status: 'open',
          ),
        );
        a.setOffline(false);
        await a.sync();
        expect(a.error, isNull);
        await b.sync();
        await b.chooseTrip(trip);
        await b.setDownloaded(trip, true);
        await b.sync();
        expect(b.error, isNull);
        final people = [
          for (var i = 0; i < 4; i++)
            <String, dynamic>{
              'id': uuid.v4(),
              'name': 'Член семьи $i',
              'phone': i < 2 ? '+7 900 111-22-33' : '',
              'birth_date': null,
              'notes': '',
              'archived': false,
            },
        ];
        final members = [
          for (var i = 0; i < 3; i++)
            <String, dynamic>{
              'id': uuid.v4(),
              'person_id': people[i]['id'],
              'role': 'client',
              'parameters': {'height_cm': 170 + i},
            },
        ];
        final ids = members.map((m) => m['id'] as String).toList();
        a.setOffline(true);
        await a.saveBooking({
          'contact_name': 'Контакт вне сплава',
          'contact_person_id': people.last['id'],
          'phone': '+7 900 111-22-33',
          'notes': 'Семья',
          'members': members,
        }, newPeople: people);
        await a.setParticipationStatus(ids.toSet(), 'confirmed');
        expect(a.peopleView.commands, hasLength(6));
        expect(a.peopleView.confirmedCount, 0);
        await a.close();
        a = await open('a', clientA, transport);
        a.setOffline(true);
        await a.chooseTrip(trip);
        expect(a.peopleView.participations, hasLength(3));
        expect(a.peopleView.commands, hasLength(6));
        a.setOffline(false);
        await a.sync();
        expect(a.error, isNotNull);
        expect(transport.sent, hasLength(1));
        await a.close();
        a = await open('a', clientA, transport);
        await a.chooseTrip(trip);
        await a.sync();
        expect(a.error, isNull);
        expect(transport.sent, [transport.sent.first, transport.sent.first]);
        expect(a.peopleView.commands, isEmpty);
        expect(a.peopleView.confirmedCount, 3);
        expect(a.peopleView.bookings, hasLength(1));
        expect(a.peopleView.participations, hasLength(3));
        await a.setParticipationStatus({ids[0]}, 'confirmed');
        await a.sync();
        await a.setParticipationStatus(ids.skip(1).toSet(), 'waiting');
        await a.sync();
        await b.sync();
        a.setOffline(true);
        b.setOffline(true);
        await a.setParticipationStatus({ids[1]}, 'confirmed');
        await b.setParticipationStatus({ids[2]}, 'confirmed');
        a.setOffline(false);
        b.setOffline(false);
        await Future.wait([a.sync(), b.sync()]);
        await Future.wait([a.sync(), b.sync()]);
        expect(a.peopleView.confirmedCount, 3);
        expect(b.peopleView.confirmedCount, 3);
        Set<String> confirmed(Stage1Controller c) => c.peopleView.participations
            .where((p) => p.status == 'confirmed')
            .map((p) => p.id)
            .toSet();
        expect(confirmed(a), confirmed(b));
        expect(
          [
            ...a.peopleView.commands,
            ...b.peopleView.commands,
          ].where((c) => c.error == 'capacity_reached'),
          isEmpty,
        );
        a.setOffline(true);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: RosterScreen(controller: a)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Новая компания'), findsOneWidget);
        expect(
          find.textContaining('Подтверждено 3 · ориентир 2'),
          findsOneWidget,
        );
        expect(find.textContaining('Лимит превышен на 1'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await a.close();
        a = await open('a', clientA, transport);
        a.setOffline(true);
        await a.chooseTrip(trip);
        expect(a.peopleView.confirmedCount, 3);
        expect(a.peopleView.participations, hasLength(3));
      } finally {
        await a.clearAccountData();
        await b.clearAccountData();
        await a.close();
        await b.close();
      }
    },
    skip: url.isEmpty || key.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
