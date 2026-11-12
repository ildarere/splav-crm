import 'package:supabase/supabase.dart';
import 'prototype_api.dart';
import 'prototype_models.dart';
import 'stage1_models.dart';

abstract interface class Stage1Api {
  Future<void> prepare();
  Future<TripCatalog> catalog();
  Future<TripSaveResult> saveTrip(TripCommand command);
  Future<TripRoute> createRoute(RouteCommand command);
  PrototypeApi groupApi(String tripId);
}

class RouteCreationRejected implements Exception {
  const RouteCreationRejected(this.reason);
  final String reason;
}

class SupabaseStage1Api implements Stage1Api {
  SupabaseStage1Api({
    required SupabaseClient client,
    required Future<void> Function() prepare,
  }) : _client = client,
       _prepare = prepare;
  final SupabaseClient _client;
  final Future<void> Function() _prepare;
  static const _timeout = Duration(seconds: 12);

  @override
  Future<void> prepare() => _prepare();

  @override
  Future<TripCatalog> catalog() async {
    final data = await _rpc('list_trips', {});
    return TripCatalog(
      teams: (data['teams'] as List)
          .map(
            (e) => TripTeam(
              id: e['id'] as String,
              name: e['name'] as String,
              role: e['role'] as String,
            ),
          )
          .toList(),
      routes: (data['routes'] as List)
          .map(
            (e) => TripRoute(
              id: e['id'] as String,
              teamId: e['team_id'] as String,
              name: e['name'] as String,
            ),
          )
          .toList(),
      trips: (data['trips'] as List).cast<Map<String, dynamic>>(),
    );
  }

  @override
  Future<TripSaveResult> saveTrip(TripCommand command) async {
    final result = await _rpc('save_trip', {
      'p_operation_id': command.operationId,
      'p_team_id': command.draft.teamId,
      'p_trip_id': command.tripId,
      'p_expected_version': command.expectedVersion,
      'p_trip': command.draft.toJson(),
    });
    return TripSaveResult(
      trip: result['trip'] as Map<String, dynamic>?,
      reason: result['reason'] as String?,
      current: result['current'] as Map<String, dynamic>?,
    );
  }

  @override
  Future<TripRoute> createRoute(RouteCommand command) async {
    final data = await _rpc('create_route', {
      'p_operation_id': command.operationId,
      'p_team_id': command.route.teamId,
      'p_route_id': command.route.id,
      'p_name': command.route.name,
    });
    if (data['status'] == 'rejected') {
      throw RouteCreationRejected(data['reason'] as String);
    }
    final route = (data['route'] ?? data) as Map<String, dynamic>;
    return TripRoute(
      id: route['id'] as String,
      teamId: route['team_id'] as String,
      name: route['name'] as String,
    );
  }

  @override
  PrototypeApi groupApi(String tripId) => _PreparedGroupApi(
    SupabasePrototypeApi(
      client: _client,
      email: '',
      password: '',
      groupId: tripId,
    ),
  );

  Future<Map<String, dynamic>> _rpc(
    String name,
    Map<String, dynamic> params,
  ) async {
    try {
      return await _client
          .rpc<Map<String, dynamic>>(name, params: params)
          .timeout(_timeout);
    } on PostgrestException catch (error) {
      if (error.code == '42501') throw const GroupAccessDenied();
      rethrow;
    }
  }
}

/// The workspace prepares one session before processing any trip commands.
class _PreparedGroupApi implements PrototypeApi {
  _PreparedGroupApi(this.delegate);
  final PrototypeApi delegate;
  @override
  String get groupId => delegate.groupId;
  @override
  Future<void> prepare() async {}
  @override
  Future<GroupPage> pull(int after) => delegate.pull(after);
  @override
  Future<RegistrationResult> submit(RegistrationCommand command) =>
      delegate.submit(command);
}
