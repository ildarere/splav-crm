import 'prototype_models.dart';

class TripTeam {
  const TripTeam({required this.id, required this.name, required this.role});
  final String id;
  final String name;
  final String role;
  bool get canCreate => role == 'admin';
}

class TripRoute {
  const TripRoute({required this.id, required this.teamId, required this.name});
  final String id;
  final String teamId;
  final String name;
}

enum TripSyncState { synced, pending, conflict }

class TripDraft {
  const TripDraft({
    required this.teamId,
    required this.title,
    required this.routeId,
    required this.startsAt,
    required this.endsAt,
    required this.timeZone,
    required this.meetingPoint,
    required this.meetingAt,
    required this.responsibleNames,
    required this.capacity,
    required this.basePriceKopecks,
    required this.notes,
    required this.status,
  });
  final String teamId;
  final String title;
  final String routeId;
  final DateTime startsAt;
  final DateTime endsAt;
  final String timeZone;
  final String meetingPoint;
  final DateTime meetingAt;
  final String responsibleNames;
  final int capacity;
  final int basePriceKopecks;
  final String notes;
  final String status;

  Map<String, dynamic> toJson() => {
    'route_id': routeId,
    'title': title,
    'starts_at': startsAt.toUtc().toIso8601String(),
    'ends_at': endsAt.toUtc().toIso8601String(),
    'timezone': timeZone,
    'meeting_point': meetingPoint,
    'meeting_at': meetingAt.toUtc().toIso8601String(),
    'responsible_names': responsibleNames,
    'capacity': capacity,
    'base_price_kopeks': basePriceKopecks,
    'notes': notes,
    'status': status,
  };

  factory TripDraft.fromJson(Map<String, dynamic> data, String teamId) =>
      TripDraft(
        teamId: teamId,
        title: data['title'] as String,
        routeId: data['route_id'] as String,
        startsAt: DateTime.parse(data['starts_at'] as String),
        endsAt: DateTime.parse(data['ends_at'] as String),
        timeZone: data['timezone'] as String,
        meetingPoint: data['meeting_point'] as String,
        meetingAt: DateTime.parse(data['meeting_at'] as String),
        responsibleNames: data['responsible_names'] as String,
        capacity: data['capacity'] as int,
        basePriceKopecks: data['base_price_kopeks'] as int,
        notes: data['notes'] as String,
        status: data['status'] as String,
      );
}

class Trip extends TripDraft {
  Trip({
    required this.id,
    required this.route,
    required this.version,
    required this.isDownloaded,
    this.syncState = TripSyncState.synced,
    this.downloadRequested = false,
    this.conflictReason,
    this.serverTrip,
    this.lastSyncedAt,
    this.bookedClients = 0,
    this.confirmedClients = 0,
    this.waitingClients = 0,
    this.instructors = 0,
    this.importMetadata = const {},
    required TripDraft draft,
  }) : super(
         teamId: draft.teamId,
         title: draft.title,
         routeId: draft.routeId,
         startsAt: draft.startsAt,
         endsAt: draft.endsAt,
         timeZone: draft.timeZone,
         meetingPoint: draft.meetingPoint,
         meetingAt: draft.meetingAt,
         responsibleNames: draft.responsibleNames,
         capacity: draft.capacity,
         basePriceKopecks: draft.basePriceKopecks,
         notes: draft.notes,
         status: draft.status,
       );

  final String id;
  final String route;
  final int version;
  final bool isDownloaded;
  final bool downloadRequested;
  final TripSyncState syncState;
  final String? conflictReason;
  final Trip? serverTrip;
  final DateTime? lastSyncedAt;
  final int bookedClients;
  final int confirmedClients;
  final int waitingClients;
  final int instructors;
  final Map<String, dynamic> importMetadata;
  bool get capacityKnown => importMetadata['capacity_known'] != false;
  bool get dateOnly => importMetadata['date_only'] == true;
}

class TripCommand {
  const TripCommand({
    required this.operationId,
    required this.tripId,
    required this.expectedVersion,
    required this.draft,
  });
  final String operationId;
  final String tripId;
  final int expectedVersion;
  final TripDraft draft;
}

class RouteCommand {
  const RouteCommand({required this.operationId, required this.route});
  final String operationId;
  final TripRoute route;
}

class TripSaveResult {
  const TripSaveResult({this.trip, this.reason, this.current});
  final Map<String, dynamic>? trip;
  final String? reason;
  final Map<String, dynamic>? current;
}

class TripCatalog {
  const TripCatalog({
    required this.teams,
    required this.routes,
    required this.trips,
  });
  final List<TripTeam> teams;
  final List<TripRoute> routes;
  final List<Map<String, dynamic>> trips;
}

class Stage1View {
  const Stage1View({
    this.teams = const [],
    this.routes = const [],
    this.trips = const [],
    this.participants = const [],
    this.pendingCommandCount = 0,
  });
  final List<TripTeam> teams;
  final List<TripRoute> routes;
  final List<Trip> trips;
  final List<PrototypeParticipant> participants;
  final int pendingCommandCount;
}
