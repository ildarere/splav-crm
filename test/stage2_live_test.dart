import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splav/core/prototype.dart';
import 'package:supabase/supabase.dart';
import 'package:uuid/uuid.dart';

class _DropBookingReply implements PeopleApi {
  _DropBookingReply(this.delegate);
  final PeopleApi delegate;
  final bookingCalls = <String>[];
  bool drop = true;
  @override
  Future<JsonMap> catalog() => delegate.catalog();
  @override
  Future<JsonMap> roster(String id, int revision) =>
      delegate.roster(id, revision);
  @override
  Future<JsonMap> submit(PeopleCommand command) async {
    final result = await delegate.submit(command);
    if (command.kind == 'save_booking') {
      bookingCalls.add(command.id);
      if (drop) {
        drop = false;
        throw const SocketException('Lost committed booking response');
      }
    }
    return result;
  }
}

void main() {
  final key = Platform.environment['SPLAV_SUPABASE_KEY'];
  final url =
      Platform.environment['SPLAV_SUPABASE_URL'] ?? 'http://127.0.0.1:54321';
  test(
    'family queue reopens, replays, resolves capacity, waits, restores and races across two clients',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'splav-stage2-live-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final warning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(
        () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = warning,
      );
      const uuid = Uuid();
      SupabaseClient client() {
        final value = SupabaseClient(
          url,
          key!,
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        addTearDown(value.dispose);
        return value;
      }

      final clientA = client(), clientB = client();
      final apiA = _DropBookingReply(SupabasePeopleApi(clientA));
      Future<Stage1Controller> open(
        String file,
        SupabaseClient client,
        PeopleApi peopleApi,
      ) async {
        Future<void> prepare() async {
          if (client.auth.currentSession == null) {
            await client.auth.signInWithPassword(
              email: 'organizer-a@example.com',
              password: 'local-splav-demo-2026',
            );
          }
        }

        final controller = Stage1Controller(
          PrototypeDatabase(
            NativeDatabase(File('${directory.path}/$file.sqlite')),
          ),
          SupabaseStage1Api(client: client, prepare: prepare),
          peopleApi: peopleApi,
          retryInterval: null,
        );
        addTearDown(controller.close);
        await controller.initialize(autoSync: false);
        return controller;
      }

      var a = await open('a', clientA, apiA);
      final b = await open('b', clientB, SupabasePeopleApi(clientB));
      await a.sync();
      expect(a.error, isNull);
      final team = a.teams.firstWhere((t) => t.canCreate);
      final route = a.routes.firstWhere((r) => r.teamId == team.id);
      a.setOffline(true);
      final tripId = await a.saveTrip(
        TripDraft(
          teamId: team.id,
          title: 'Семья · проверка ${uuid.v4()}',
          routeId: route.id,
          startsAt: DateTime.utc(2033, 8, 1, 5),
          endsAt: DateTime.utc(2033, 8, 2, 14),
          timeZone: 'Europe/Saratov',
          meetingPoint: 'Причал',
          meetingAt: DateTime.utc(2033, 8, 1, 4, 30),
          responsibleNames: 'Организатор',
          capacity: 2,
          basePriceKopecks: 700000,
          notes: 'Проверка этапа 2',
          status: 'open',
        ),
      );
      a.setOffline(false);
      await a.sync();
      expect(a.error, isNull);
      expect(a.peopleView.ready, isTrue);
      await b.sync();
      await b.chooseTrip(tripId);
      await b.setDownloaded(tripId, true);
      await b.sync();
      expect(b.peopleView.ready, isTrue);
      final people = [
        for (var i = 0; i < 4; i++)
          <String, dynamic>{
            'id': uuid.v4(),
            'name': 'Тест семьи $i ${uuid.v4()}',
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
            'parameters': {'clothing_size': '48', 'height_cm': 170 + i},
          },
      ];
      final ids = members.map((p) => p['id'] as String).toList();
      a.setOffline(true);
      await a.saveBooking({
        'contact_name': 'Контакт семьи',
        'contact_person_id': people.last['id'],
        'phone': '+7 900 111-22-33',
        'notes': 'Семья из троих',
        'members': members,
      }, newPeople: people);
      await a.setParticipationStatus(ids.toSet(), 'confirmed');
      expect(a.peopleView.bookings, hasLength(1));
      expect(a.peopleView.participations, hasLength(3));
      expect(a.peopleView.confirmedCount, 0);
      await a.close();
      a = await open('a', clientA, apiA);
      a.setOffline(true);
      await a.chooseTrip(tripId);
      expect(a.peopleView.participations, hasLength(3));
      expect(a.peopleView.commands, hasLength(6));
      a.setOffline(false);
      await a.sync();
      expect(a.error, isNotNull);
      expect(apiA.bookingCalls, hasLength(1));
      await a.close();
      a = await open('a', clientA, apiA);
      await a.chooseTrip(tripId);
      await a.sync();
      expect(a.error, isNull);
      expect(apiA.bookingCalls, [
        apiA.bookingCalls.first,
        apiA.bookingCalls.first,
      ]);
      expect(a.peopleView.commands, isEmpty);
      expect(a.peopleView.confirmedCount, 3);
      expect(a.peopleView.bookings, hasLength(1));
      await b.sync();
      expect(b.peopleView.participations, hasLength(3));
      expect(
        b.peopleView.people.where(
          (p) => people.any((newPerson) => newPerson['id'] == p.id),
        ),
        hasLength(4),
      );
      await a.setParticipationStatus({ids[2]}, 'waiting');
      await a.sync();
      await a.setParticipationStatus(ids.take(2).toSet(), 'confirmed');
      await a.sync();
      expect(a.peopleView.confirmedCount, 2);
      await a.setParticipationStatus({ids[2]}, 'waiting');
      await a.sync();
      expect(
        a.peopleView.participations.firstWhere((p) => p.id == ids[2]).waitingAt,
        isNotNull,
      );
      await a.setParticipationStatus({ids[0]}, 'cancelled');
      await a.sync();
      expect(a.peopleView.confirmedCount, 1);
      await a.setParticipationStatus({ids[0]}, 'application');
      await a.sync();
      expect(a.peopleView.participations, hasLength(3));
      await b.sync();
      a.setOffline(true);
      b.setOffline(true);
      await a.setParticipationStatus({ids[0]}, 'confirmed');
      await b.setParticipationStatus({ids[2]}, 'confirmed');
      a.setOffline(false);
      b.setOffline(false);
      await Future.wait([a.sync(), b.sync()]);
      await Future.wait([a.sync(), b.sync()]);
      expect(a.peopleView.confirmedCount, 3);
      expect(b.peopleView.confirmedCount, 3);
      final confirmedA = a.peopleView.participations
          .where((p) => p.status == 'confirmed')
          .map((p) => p.id)
          .toSet();
      final confirmedB = b.peopleView.participations
          .where((p) => p.status == 'confirmed')
          .map((p) => p.id)
          .toSet();
      expect(confirmedA, confirmedB);
      expect(
        [
          ...a.peopleView.commands,
          ...b.peopleView.commands,
        ].where((c) => c.error == 'capacity_reached'),
        isEmpty,
      );
      final history = await a.database.personHistory(
        people.first['id'] as String,
      );
      expect(history.single['parameters']['height_cm'], 170);
    },
    skip: key == null
        ? 'Requires local Supabase and SPLAV_SUPABASE_KEY'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
