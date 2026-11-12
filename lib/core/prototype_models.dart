enum ParticipantStatus { pending, confirmed, rejected }

class PrototypeGroup {
  const PrototypeGroup({
    required this.id,
    required this.title,
    required this.route,
    required this.startsAt,
    required this.capacity,
  });

  final String id;
  final String title;
  final String route;
  final DateTime startsAt;
  final int capacity;
}

class PrototypeParticipant {
  const PrototypeParticipant({
    required this.id,
    required this.name,
    required this.status,
    this.reason,
  });

  final String id;
  final String name;
  final ParticipantStatus status;
  final String? reason;
}

class RegistrationCommand {
  const RegistrationCommand({
    required this.operationId,
    required this.groupId,
    required this.personId,
    required this.registrationId,
    required this.name,
  });

  final String operationId;
  final String groupId;
  final String personId;
  final String registrationId;
  final String name;
}

class RegistrationResult {
  const RegistrationResult.accepted(this.revision) : reason = null;
  const RegistrationResult.rejected(this.reason) : revision = null;

  final int? revision;
  final String? reason;
}

class RegistrationChange {
  const RegistrationChange({required this.revision, required this.command});

  final int revision;
  final RegistrationCommand command;
}

class GroupPage {
  const GroupPage({
    required this.group,
    required this.changes,
    required this.cursor,
    required this.hasMore,
  });

  final PrototypeGroup group;
  final List<RegistrationChange> changes;
  final int cursor;
  final bool hasMore;
}

class LocalGroupView {
  const LocalGroupView({
    this.group,
    this.participants = const [],
    this.cursor = 0,
    this.lastSyncedAt,
  });

  final PrototypeGroup? group;
  final List<PrototypeParticipant> participants;
  final int cursor;
  final DateTime? lastSyncedAt;
}
