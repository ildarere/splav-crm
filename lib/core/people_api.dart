import 'package:supabase/supabase.dart';
import 'prototype_api.dart';
import 'people_models.dart';

abstract interface class PeopleApi {
  Future<JsonMap> catalog();
  Future<JsonMap> roster(String tripId, int revision);
  Future<JsonMap> submit(PeopleCommand command);
}

class SupabasePeopleApi implements PeopleApi {
  SupabasePeopleApi(this.client);
  final SupabaseClient client;
  Future<JsonMap> _rpc(String name, JsonMap args) async {
    try {
      return await client
          .rpc<JsonMap>(name, params: args)
          .timeout(const Duration(seconds: 12));
    } on PostgrestException catch (error) {
      if (error.code == '42501') throw const GroupAccessDenied();
      rethrow;
    }
  }

  @override
  Future<JsonMap> catalog() => _rpc('people_catalog', {});
  @override
  Future<JsonMap> roster(String tripId, int revision) => _rpc(
    'roster_snapshot',
    {'p_trip_id': tripId, 'p_after_revision': revision},
  );
  @override
  Future<JsonMap> submit(PeopleCommand command) async {
    try {
      return await _rpc('people_command', {
        'p_operation_id': command.id,
        'p_team_id': command.teamId,
        'p_trip_id': command.tripId,
        'p_kind': command.kind,
        'p_payload': command.payload,
        'p_expected_version': command.expectedVersion,
      });
    } on PostgrestException catch (error) {
      if (error.code == 'P0001' && error.message == 'work_schedule_overlap') {
        return {'status': 'rejected', 'reason': 'work_schedule_overlap'};
      }
      if ([
        '22023',
        '22P02',
        '22007',
        '22003',
        '22008',
        '23505',
        '23514',
      ].contains(error.code)) {
        return {'status': 'rejected', 'reason': 'invalid_fields'};
      }
      rethrow;
    }
  }
}
