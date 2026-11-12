import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:splav/core/prototype.dart';
import 'package:supabase/supabase.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_ANON_KEY');

  testWidgets(
    'two trips and their queues survive reopening on the device',
    (tester) async {
      final client = SupabaseClient(
        url,
        key,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      await client.auth.signInWithPassword(
        email: 'organizer-a@example.com',
        password: 'local-splav-demo-2026',
      );
      final api = SupabaseStage1Api(client: client, prepare: () async {});
      final scope = 'stage1-device-${DateTime.now().microsecondsSinceEpoch}';
      Future<Stage1Controller> open() async {
        final db = await PrototypeDatabase.open(scope: scope);
        final controller = Stage1Controller(db, api, retryInterval: null);
        await controller.initialize(autoSync: false);
        return controller;
      }

      var controller = await open();
      try {
        await controller.sync();
        expect(controller.error, isNull);
        final team = controller.teams.firstWhere((team) => team.canCreate);
        final route = controller.routes.firstWhere(
          (route) => route.teamId == team.id,
        );
        controller.setOffline(true);
        TripDraft draft(String title, int day, int capacity) => TripDraft(
          teamId: team.id,
          title: title,
          routeId: route.id,
          startsAt: DateTime.utc(2031, 8, day, 5),
          endsAt: DateTime.utc(2031, 8, day + 1, 12),
          timeZone: 'Europe/Saratov',
          meetingPoint: 'Тестовый сбор',
          meetingAt: DateTime.utc(2031, 8, day, 4, 30),
          responsibleNames: 'Тестовый организатор',
          capacity: capacity,
          basePriceKopecks: 700000,
          notes: 'Проверка устройства',
          status: 'open',
        );
        final first = await controller.saveTrip(
          draft('Проверка устройства A', 1, 3),
        );
        final second = await controller.saveTrip(
          draft('Проверка устройства B', 8, 5),
        );
        expect(controller.pendingCommandCount, 2);
        await controller.close();
        controller = await open();
        controller.setOffline(true);
        expect(controller.pendingCommandCount, 2);
        expect(
          controller.trips.firstWhere((trip) => trip.id == first).capacity,
          3,
        );
        expect(
          controller.trips.firstWhere((trip) => trip.id == second).capacity,
          5,
        );
        controller.setOffline(false);
        await controller.sync();
        expect(controller.error, isNull);
        expect(controller.pendingCommandCount, 0);
        expect(
          controller.trips.firstWhere((trip) => trip.id == first).isDownloaded,
          isTrue,
        );
        expect(
          controller.trips.firstWhere((trip) => trip.id == second).isDownloaded,
          isTrue,
        );
        controller.setOffline(true);
        await controller.chooseTrip(first);
        await controller.addParticipant('Участник проверки устройства');
        await controller.close();
        controller = await open();
        controller.setOffline(true);
        await controller.chooseTrip(first);
        expect(
          controller.selectedParticipants.single.status,
          ParticipantStatus.pending,
        );
        await controller.chooseTrip(second);
        expect(controller.selectedTrip?.capacity, 5);
        controller.setOffline(false);
        await controller.sync();
        expect(controller.error, isNull);
        await controller.chooseTrip(first);
        expect(
          controller.selectedParticipants.single.status,
          ParticipantStatus.confirmed,
        );
        expect(controller.pendingCommandCount, 0);
      } finally {
        await controller.clearAccountData();
        await controller.close();
      }
    },
    skip: url.isEmpty || key.isEmpty,
  );
}
