import 'package:supabase/supabase.dart';

import 'prototype_models.dart';

abstract interface class PrototypeApi {
  String get groupId;

  Future<void> prepare();
  Future<RegistrationResult> submit(RegistrationCommand command);
  Future<GroupPage> pull(int after);
}

class GroupAccessDenied implements Exception {
  const GroupAccessDenied();
}

class SupabasePrototypeApi implements PrototypeApi {
  SupabasePrototypeApi({
    required SupabaseClient client,
    required String email,
    required String password,
    required this.groupId,
  }) : _client = client,
       _email = email,
       _password = password;

  static const _timeout = Duration(seconds: 8);
  final SupabaseClient _client;
  final String _email;
  final String _password;

  @override
  final String groupId;

  @override
  Future<void> prepare() async {
    final session = _client.auth.currentSession;
    if (session != null && !session.isExpired && session.user.email == _email) {
      return;
    }
    await _client.auth
        .signInWithPassword(email: _email, password: _password)
        .timeout(_timeout);
  }

  @override
  Future<RegistrationResult> submit(RegistrationCommand command) async {
    final result = await _rpc('submit_registration', {
      'p_group_id': groupId,
      'p_operation_id': command.operationId,
      'p_person_id': command.personId,
      'p_registration_id': command.registrationId,
      'p_name': command.name,
    });
    return switch (result['status']) {
      'accepted' => RegistrationResult.accepted(result['revision'] as int),
      'rejected' => RegistrationResult.rejected(result['reason'] as String),
      _ => throw const FormatException('Unexpected registration status'),
    };
  }

  @override
  Future<GroupPage> pull(int after) async {
    final data = await _rpc('pull_group', {
      'p_group_id': groupId,
      'p_after_revision': after,
    });
    final group = data['group'] as Map<String, dynamic>;
    final changes = (data['changes'] as List).cast<Map<String, dynamic>>();
    return GroupPage(
      group: PrototypeGroup(
        id: group['id'] as String,
        title: group['title'] as String,
        route: group['route'] as String,
        startsAt: DateTime.parse(group['starts_at'] as String),
        capacity: group['capacity'] as int,
      ),
      changes: changes
          .map((entry) {
            final person = entry['person'] as Map<String, dynamic>;
            final registration = entry['registration'] as Map<String, dynamic>;
            return RegistrationChange(
              revision: entry['revision'] as int,
              command: RegistrationCommand(
                operationId: entry['operation_id'] as String,
                groupId: registration['group_id'] as String,
                personId: person['id'] as String,
                registrationId: registration['id'] as String,
                name: person['name'] as String,
              ),
            );
          })
          .toList(growable: false),
      cursor: data['cursor'] as int,
      hasMore: data['has_more'] as bool,
    );
  }

  Future<Map<String, dynamic>> _rpc(
    String function,
    Map<String, dynamic> params,
  ) async {
    try {
      return await _client
          .rpc<Map<String, dynamic>>(function, params: params)
          .timeout(_timeout);
    } on PostgrestException catch (error) {
      if (error.code == '42501') throw const GroupAccessDenied();
      rethrow;
    }
  }
}
