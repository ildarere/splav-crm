import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' show ClientException;
import 'package:supabase/supabase.dart' show AuthRetryableFetchException;
import 'package:uuid/uuid.dart';
import 'prototype_api.dart';
import 'prototype_database.dart';
import 'prototype_models.dart';
import 'stage1_api.dart';
import 'stage1_database.dart';
import 'stage1_models.dart';
import 'people_api.dart';
import 'people_database.dart';
import 'people_models.dart';
import 'trip_dates.dart';
import 'finance_models.dart';
import 'operations_models.dart';

class Stage1Controller extends ChangeNotifier {
  Stage1Controller(
    this.database,
    this.api, {
    this.peopleApi,
    Duration? retryInterval = const Duration(seconds: 20),
  }) : _retryInterval = retryInterval;
  final PrototypeDatabase database;
  final Stage1Api api;
  final PeopleApi? peopleApi;
  PeopleView _people = const PeopleView();
  PeopleView get peopleView => _people;
  FinanceView _finance = const FinanceView();
  FinanceView get financeView => _finance;
  OperationsView _operations = const OperationsView();
  OperationsView get operationsView => _operations;
  final String deviceId = const Uuid().v4();
  bool get hasPeople => peopleApi != null;
  final Duration? _retryInterval;
  final _uuid = const Uuid();
  Stage1View _view = const Stage1View();
  String? _selectedTripId;
  String? _error;
  bool _offline = false;
  bool _connectionOffline = false;
  bool _syncAgain = false;
  bool _syncing = false;
  bool _disposed = false;
  Timer? _timer;
  Timer? _pushTimer;
  bool _autoRetry = false;
  int _failures = 0;
  Future<void>? _syncFuture;
  Future<void>? _closeFuture;

  List<TripTeam> get teams => _view.teams;
  List<TripRoute> get routes => _view.routes;
  List<Trip> get trips => _view.trips;
  String? get selectedTripId => _selectedTripId;
  Trip? get selectedTrip =>
      trips.where((t) => t.id == _selectedTripId).firstOrNull;
  List<PrototypeParticipant> get selectedParticipants => _view.participants;
  int get selectedConfirmedCount => hasPeople && _people.ready
      ? _people.confirmedCount
      : selectedParticipants
            .where((p) => p.status == ParticipantStatus.confirmed)
            .length;
  int get selectedPendingCount => hasPeople && _people.ready
      ? _people.participations.where((p) => p.pending).length
      : selectedParticipants
            .where((p) => p.status == ParticipantStatus.pending)
            .length;
  int get pendingCommandCount =>
      _view.pendingCommandCount + _people.commands.length;
  bool get canCreateTrips => teams.any((t) => t.canCreate);
  bool get isOffline => _offline || _connectionOffline;
  bool get isSyncing => _syncing;
  String? get error => _error;
  DateTime? get lastSyncedAt =>
      hasPeople ? _people.syncedAt : selectedTrip?.lastSyncedAt;

  Future<void> initialize({bool autoSync = true}) async {
    await _refresh();
    if (!autoSync || _disposed) return;
    _autoRetry = true;
    unawaited(sync());
  }

  Future<void> chooseTrip(String id) async {
    _selectedTripId = id;
    final trip = trips.where((t) => t.id == id).firstOrNull;
    if (hasPeople && trip != null && !trip.downloadRequested) {
      await database.requestDownload(id, true);
      _scheduleSync();
    }
    await _refresh();
  }

  void setOffline(bool value) {
    if (_disposed || _offline == value) return;
    _offline = value;
    _notify();
    if (!value) unawaited(sync());
  }

  Future<String> saveTrip(TripDraft draft, {String? tripId}) async {
    _validateDraft(draft);
    final previous = tripId == null
        ? null
        : trips.where((t) => t.id == tripId).firstOrNull;
    if (tripId != null && previous == null) {
      throw StateError('Выезд недоступен.');
    }
    if (previous == null &&
        !teams.any((t) => t.id == draft.teamId && t.canCreate)) {
      throw StateError('Создавать выезды может администратор команды.');
    }
    if (previous != null && previous.teamId != draft.teamId) {
      throw StateError('Команду выезда нельзя изменить.');
    }
    final id = tripId ?? _uuid.v4();
    await database.transaction(() async {
      if (previous?.syncState == TripSyncState.conflict) {
        await database.discardTripCommand(id);
      }
      await database.queueTrip(
        TripCommand(
          operationId: _uuid.v4(),
          tripId: id,
          expectedVersion:
              previous?.serverTrip?.version ?? previous?.version ?? 0,
          draft: draft,
        ),
      );
    });
    _selectedTripId = id;
    await _refresh();
    _scheduleSync();
    return id;
  }

  Future<void> createTrips(List<TripDraft> drafts) async {
    if (drafts.isEmpty) return;
    for (final draft in drafts) {
      _validateDraft(draft);
      if (!teams.any((team) => team.id == draft.teamId && team.canCreate)) {
        throw StateError('Создавать выезды может администратор команды.');
      }
    }
    final commands = [
      for (final draft in drafts)
        TripCommand(
          operationId: _uuid.v4(),
          tripId: _uuid.v4(),
          expectedVersion: 0,
          draft: draft,
        ),
    ];
    await database.transaction(() async {
      for (final command in commands) {
        await database.queueTrip(command);
      }
    });
    _selectedTripId = commands.last.tripId;
    await _refresh();
    _scheduleSync();
  }

  Future<void> createRoute(String value, {required String teamId}) async {
    final name = value.trim();
    if (name.isEmpty || name.runes.length > 150) {
      throw ArgumentError(
        'Название маршрута должно содержать от 1 до 150 символов.',
      );
    }
    if (!teams.any((t) => t.id == teamId && t.canCreate)) {
      throw StateError('Маршруты создаёт администратор команды.');
    }
    await database.queueRoute(
      RouteCommand(
        operationId: _uuid.v4(),
        route: TripRoute(id: _uuid.v4(), teamId: teamId, name: name),
      ),
    );
    await _refresh();
    _scheduleSync();
  }

  Future<void> setDownloaded(String tripId, bool value) async {
    await database.requestDownload(tripId, value);
    await _refresh();
    if (value) _scheduleSync();
  }

  Future<void> addParticipant(String value) async {
    final trip = selectedTrip;
    if (trip == null || !trip.isDownloaded) {
      throw StateError('Сначала загрузите состав выезда.');
    }
    if (trip.version == 0) {
      throw StateError('Сначала синхронизируйте новый выезд.');
    }
    if (trip.status != 'open') {
      throw StateError('Запись на этот выезд закрыта.');
    }
    final name = value.trim();
    if (name.isEmpty || name.runes.length > 100) {
      throw ArgumentError('Введите имя длиной от 1 до 100 символов.');
    }
    await database.enqueue(
      RegistrationCommand(
        operationId: _uuid.v4(),
        groupId: trip.id,
        personId: _uuid.v4(),
        registrationId: _uuid.v4(),
        name: name,
      ),
    );
    await _refresh();
    _scheduleSync();
  }

  Future<void> retryConflict(String tripId) async {
    final trip = trips.firstWhere((t) => t.id == tripId);
    if (trip.syncState != TripSyncState.conflict) {
      throw StateError('Сначала дождитесь результата синхронизации.');
    }
    await database.transaction(() async {
      await database.discardTripCommand(tripId);
      await database.queueTrip(
        TripCommand(
          operationId: _uuid.v4(),
          tripId: tripId,
          expectedVersion: trip.serverTrip?.version ?? trip.version,
          draft: trip,
        ),
      );
    });
    await _refresh();
    _scheduleSync();
  }

  Future<void> discardConflict(String tripId) async {
    final trip = trips.firstWhere((t) => t.id == tripId);
    if (trip.syncState != TripSyncState.conflict) {
      throw StateError('Сначала дождитесь результата синхронизации.');
    }
    await database.discardTripCommand(tripId);
    await _refresh();
  }

  void _validateDraft(TripDraft draft) {
    if (draft.title.trim().isEmpty || draft.title.runes.length > 150) {
      throw ArgumentError('Введите название выезда до 150 символов.');
    }
    if (!draft.endsAt.isAfter(draft.startsAt)) {
      throw ArgumentError('Окончание должно быть позже начала.');
    }
    if (draft.meetingAt.isAfter(draft.startsAt)) {
      throw ArgumentError('Сбор должен быть до начала выезда.');
    }
    if (draft.capacity < 1 || draft.capacity > 100000) {
      throw ArgumentError('Укажите лимит от 1 до 100000 участников.');
    }
    if (draft.basePriceKopecks < 0 || draft.basePriceKopecks > 1000000000) {
      throw ArgumentError(
        'Укажите неотрицательную стоимость в допустимом диапазоне.',
      );
    }
    if (!routes.any((r) => r.id == draft.routeId && r.teamId == draft.teamId)) {
      throw ArgumentError('Выберите маршрут команды.');
    }
  }

  void _scheduleSync() {
    if (_disposed || _offline) return;
    if (_syncFuture != null) {
      _syncAgain = true;
      return;
    }
    _pushTimer?.cancel();
    _pushTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(sync()),
    );
  }

  Future<void> sync() {
    _pushTimer?.cancel();
    if (_syncFuture case final running?) return running;
    if (_disposed || _offline) return Future.value();
    return _syncFuture = Future<void>.microtask(_runSync).whenComplete(() {
      _syncFuture = null;
      if (_syncAgain) {
        _syncAgain = false;
        _scheduleSync();
      }
    });
  }

  Future<void> _runSync() async {
    if (_disposed || _offline) return;
    _timer?.cancel();
    _syncing = true;
    _error = null;
    _notify();
    var touchedLocal = false;
    try {
      await api.prepare();
      // Refresh access before replaying any queued operation.
      final catalog = await api.catalog();
      touchedLocal = true;
      await _cacheCatalog(catalog);
      for (final command in await database.routeCommands()) {
        if (_disposed || _offline) return;
        try {
          await database.applyRouteResult(
            command,
            await api.createRoute(command),
          );
        } on RouteCreationRejected catch (rejection) {
          await database.rejectRoute(command, rejection.reason);
          _error =
              'Маршрут с таким названием уже существует. Выберите существующий маршрут для выезда.';
        } on GroupAccessDenied {
          await database.rejectRoute(command, 'access_denied');
          _error =
              'Доступ к созданию маршрута отозван. Проверьте связанные выезды.';
        }
      }
      for (final command in await database.tripCommands()) {
        if (_disposed || _offline) return;
        try {
          await database.applyTripResult(command, await api.saveTrip(command));
        } on GroupAccessDenied {
          await database.deleteTripCache(command.tripId);
          _error =
              'Доступ к одному из выездов отозван. Его локальные данные удалены.';
        }
      }
      final tripView = await database.readWorkspace(null);
      if (hasPeople) {
        for (final trip in tripView.trips.where(
          (t) => !t.downloadRequested && inHomeWindow(t, DateTime.now()),
        )) {
          await database.requestDownload(trip.id, true);
        }
      }
      for (final id in await database.requestedTripIds()) {
        if (_disposed || _offline) return;
        if (!tripView.trips.any((t) => t.id == id && t.version > 0)) continue;
        final legacyCommands = await database.pendingCommands(id);
        if (hasPeople && legacyCommands.isEmpty) continue;
        final groupApi = api.groupApi(id);
        try {
          for (final command in legacyCommands) {
            if (_disposed || _offline) return;
            final result = await groupApi.submit(command);
            if (result.reason case final reason?) {
              await database.reject(command, reason);
            }
          }
          var cursor = (await database.readGroup(id)).cursor;
          while (!_disposed && !_offline) {
            final page = await groupApi.pull(cursor);
            if (page.group.id != id ||
                page.cursor < cursor ||
                (page.hasMore && page.cursor == cursor)) {
              throw const FormatException('Invalid group journal cursor');
            }
            await database.applyPage(page);
            if (!page.hasMore) {
              if (!hasPeople) await database.markDownloaded(id);
              break;
            }
            cursor = page.cursor;
          }
        } on GroupAccessDenied {
          await database.deleteTripCache(id);
          _error =
              'Доступ к одному из выездов отозван. Его локальные данные удалены.';
        }
      }
      if (!_disposed && !_offline && hasPeople) await _syncPeople();
      if (!_disposed && !_offline) {
        await _cacheCatalog(await api.catalog(), loadPeople: false);
      }
      _connectionOffline = false;
      _failures = 0;
    } catch (failure) {
      _failures++;
      _connectionOffline =
          failure is IOException ||
          failure is TimeoutException ||
          failure is ClientException ||
          failure is AuthRetryableFetchException;
      _error = _connectionOffline
          ? 'Нет связи с сервером. Работаем с сохранёнными данными; обмен возобновится автоматически.'
          : 'Обмен не завершён. Изменения сохранены; приложение повторит попытку автоматически.';
    } finally {
      _syncing = false;
      try {
        if (touchedLocal) {
          await _refresh();
        } else {
          _notify();
        }
      } catch (_) {
        _error = 'Не удалось прочитать данные на устройстве.';
        _notify();
      }
      _scheduleRetry();
    }
  }

  Future<void> _cacheCatalog(
    TripCatalog catalog, {
    bool loadPeople = true,
  }) async {
    final before = await database.readWorkspace(null);
    final removed = before.trips.any(
      (old) => !catalog.trips.any((t) => t['id'] == old.id),
    );
    final people = hasPeople && (loadPeople || removed)
        ? await peopleApi!.catalog()
        : null;
    await database.transaction(() async {
      await database.cacheCatalog(
        catalog,
        accessiblePeople: {
          for (final p in people?['people'] as List? ?? []) p['id'] as String,
        },
      );
      if (people != null) await database.cachePeople(people);
    });
    final after = await database.readWorkspace(null);
    if (before.trips.any(
      (old) => !after.trips.any((trip) => trip.id == old.id),
    )) {
      _error =
          'Доступ к выезду отозван. Его загруженные данные и локальные изменения удалены.';
    }
  }

  void _scheduleRetry() {
    final interval = _retryInterval;
    if (!_autoRetry || interval == null || _disposed || _offline) return;
    final exponent = (_failures - 1).clamp(0, 4);
    final milliseconds =
        (_connectionOffline
                ? interval.inMilliseconds.clamp(1, 3000)
                : interval.inMilliseconds * (1 << exponent))
            .clamp(1, 300000);
    _timer = Timer(
      Duration(milliseconds: milliseconds),
      () => unawaited(sync()),
    );
  }

  Future<void> _refresh() async {
    _view = await database.readWorkspace(_selectedTripId);
    if (!trips.any((t) => t.id == _selectedTripId)) {
      _selectedTripId = trips.firstOrNull?.id;
      _view = await database.readWorkspace(_selectedTripId);
    }
    _people = await database.readPeople(_selectedTripId);
    _finance = FinanceView.project(
      _selectedTripId == null
          ? null
          : await database.serverRoster(_selectedTripId!),
      _people.commands.where((c) => c.tripId == _selectedTripId).toList(),
    );
    _operations = OperationsView.project(
      _selectedTripId == null
          ? null
          : await database.serverRoster(_selectedTripId!),
      _people.commands,
      _people,
    );
    _notify();
  }

  Future<void> _loadRoster(String id) async {
    final snapshot = await peopleApi!.roster(
      id,
      await database.rosterRevision(id),
    );
    await database.transaction(() async {
      await database.cacheRoster(snapshot);
      await database.markDownloaded(id);
    });
  }

  Future<void> _syncPeople() async {
    await database.cachePeople(await peopleApi!.catalog());
    final workspace = await database.readWorkspace(null);
    for (final id in await database.requestedTripIds()) {
      if (_disposed || _offline) return;
      if (workspace.trips.any((t) => t.id == id && t.version > 0)) {
        try {
          await _loadRoster(id);
        } on GroupAccessDenied {
          await database.deleteTripCache(id);
        }
      }
    }
    while (!_disposed && !_offline) {
      final command = await database.nextPeopleCommand();
      if (command == null) break;
      try {
        final result = await peopleApi!.submit(command);
        await database.recordPeopleResult(command, result);
        await database.cachePeople(await peopleApi!.catalog());
        if (command.tripId case final id?) await _loadRoster(id);
        if (result['status'] == 'accepted' &&
            (command.kind == 'move_participant' ||
                command.kind == 'ops_move_escort')) {
          await _loadRoster(command.payload['target_trip_id'] as String);
        }
        if (command.kind == 'merge_people') {
          for (final id in await database.requestedTripIds()) {
            await _loadRoster(id);
          }
        }
      } on GroupAccessDenied {
        // A referenced card may be unavailable even when the trip is valid.
        // Refresh actual scopes before deciding whether a draft must be purged.
        await _cacheCatalog(await api.catalog());
        await database.cachePeople(await peopleApi!.catalog());
        if ((await database.peopleCommands()).any((c) => c.id == command.id)) {
          await database.recordPeopleResult(command, {
            'reason': 'access_denied',
          });
          _error =
              'Не удалось применить изменение. Проверьте доступ к выбранным людям и состав заявки.';
        }
      }
    }
  }

  List<String> _peopleDependencies({
    Set<String> persons = const {},
    Set<String> participations = const {},
    String? bookingId,
  }) {
    final related = _people.commands
        .where(
          (c) =>
              c.personIds.any(persons.contains) ||
              c.participationIds.any(participations.contains) ||
              (bookingId != null &&
                  c.kind == 'save_booking' &&
                  c.payload['id'] == bookingId),
        )
        .toList();
    if (related.any((c) => c.error != null)) {
      throw StateError('Сначала разрешите конфликт предыдущего изменения.');
    }
    return related.map((c) => c.id).toList();
  }

  Future<String> savePerson(
    JsonMap payload, {
    required String teamId,
    PersonCard? previous,
  }) async {
    final name = (payload['name'] as String? ?? '').trim();
    if (name.isEmpty || name.runes.length > 100) {
      throw ArgumentError('Введите имя до 100 символов.');
    }
    final id = previous?.id ?? payload['id'] as String? ?? _uuid.v4();
    final conflicts = _people.commands
        .where((c) => c.error != null && c.personIds.contains(id))
        .toList();
    final version = conflicts.isEmpty
        ? previous?.version ?? 0
        : (await database.serverPerson(id))?['version'] as int? ?? 0;
    final command = PeopleCommand(
      id: _uuid.v4(),
      teamId: teamId,
      kind: 'save_person',
      payload: {...payload, 'id': id, 'name': name},
      expectedVersion: version,
      dependencies: conflicts.isEmpty ? _peopleDependencies(persons: {id}) : [],
    );
    await database.transaction(() async {
      for (final conflict in conflicts) {
        await database.discardPeople(conflict.id);
      }
      await database.queuePeople(command);
    });
    await _refresh();
    _scheduleSync();
    return id;
  }

  Future<void> saveBooking(
    JsonMap payload, {
    List<JsonMap> newPeople = const [],
    Booking? previous,
  }) async {
    final trip = selectedTrip;
    if (trip == null || !_people.ready) {
      throw StateError('Сначала загрузите состав выезда.');
    }
    final id = previous?.id ?? payload['id'] as String? ?? _uuid.v4();
    final members = (payload['members'] as List? ?? []).cast<JsonMap>();
    final personIds = {
      for (final member in members) member['person_id'] as String,
      if (payload['contact_person_id'] is String)
        payload['contact_person_id'] as String,
    };
    final dependencies = _peopleDependencies(persons: personIds, bookingId: id);
    await database.transaction(() async {
      for (final person in newPeople) {
        final op = _uuid.v4();
        dependencies.add(op);
        await database.queuePeople(
          PeopleCommand(
            id: op,
            teamId: trip.teamId,
            kind: 'save_person',
            originTripId: trip.id,
            payload: person,
          ),
        );
      }
      await database.queuePeople(
        PeopleCommand(
          id: _uuid.v4(),
          teamId: trip.teamId,
          tripId: trip.id,
          kind: 'save_booking',
          payload: {...payload, 'id': id, 'members': members},
          expectedVersion: previous?.version ?? 0,
          dependencies: dependencies,
        ),
      );
    });
    await _refresh();
    _scheduleSync();
  }

  Future<void> retryLegacyRegistration(Participation participant) async {
    if (participant.data['legacy_rejection'] != true) return;
    final person = _people.person(participant.personId);
    if (person == null) throw StateError('Карточка человека недоступна.');
    final existing = await database.serverPerson(person.id);
    await saveBooking(
      {
        'contact_person_id': person.id,
        'contact_name': person.name,
        'phone': person.phone,
        'notes': 'Заявка из предыдущей версии',
        'members': [
          {
            'id': participant.id,
            'person_id': person.id,
            'role': 'client',
            'parameters': <String, dynamic>{},
          },
        ],
      },
      newPeople: existing == null
          ? [
              {
                'id': person.id,
                'name': person.name,
                'phone': person.phone,
                'birth_date': person.birthDate,
                'notes': person.notes,
                'archived': false,
              },
            ]
          : [],
    );
  }

  Future<void> setParticipationStatus(
    Set<String> ids,
    String status, {
    bool separate = false,
  }) async {
    final trip = selectedTrip;
    if (trip == null || ids.isEmpty) return;
    final participants = _people.participations
        .where((p) => ids.contains(p.id))
        .toList();
    if (participants.length != ids.length) {
      throw StateError('Состав изменился. Обновите выбор.');
    }
    await database.queuePeople(
      PeopleCommand(
        id: _uuid.v4(),
        teamId: trip.teamId,
        tripId: trip.id,
        kind: 'set_status',
        payload: {
          'ids': ids.toList(),
          'status': status,
          if (status == 'waiting')
            'requested_at': DateTime.now().toUtc().toIso8601String(),
          if (separate) 'separate_booking_id': _uuid.v4(),
          'versions': {for (final p in participants) p.id: p.version},
        },
        dependencies: _peopleDependencies(participations: ids),
      ),
    );
    await _refresh();
    _scheduleSync();
  }

  Future<void> moveParticipant(
    Participation participant,
    Trip destination,
  ) async {
    final source = selectedTrip;
    final current = _people.participations
        .where((p) => p.id == participant.id)
        .firstOrNull;
    if (source == null ||
        source.id != participant.tripId ||
        destination.teamId != source.teamId ||
        destination.id == source.id ||
        current == null ||
        current.pending ||
        current.version != participant.version) {
      throw StateError('Состав изменился. Откройте участника заново.');
    }
    await database.queuePeople(
      PeopleCommand(
        id: _uuid.v4(),
        teamId: source.teamId,
        tripId: source.id,
        kind: 'move_participant',
        expectedVersion: participant.version,
        dependencies: _peopleDependencies(participations: {participant.id}),
        payload: {
          'id': participant.id,
          'target_trip_id': destination.id,
          'new_booking_id': _uuid.v4(),
          'new_registration_id': _uuid.v4(),
        },
      ),
    );
    await _refresh();
    _scheduleSync();
  }

  Future<void> editParticipation(
    Participation participant, {
    required String role,
    required JsonMap parameters,
  }) async {
    final trip = selectedTrip;
    if (trip == null) return;
    await database.queuePeople(
      PeopleCommand(
        id: _uuid.v4(),
        teamId: trip.teamId,
        tripId: trip.id,
        kind: 'edit_participation',
        payload: {'id': participant.id, 'role': role, 'parameters': parameters},
        expectedVersion: participant.version,
        dependencies: _peopleDependencies(participations: {participant.id}),
      ),
    );
    await _refresh();
    _scheduleSync();
  }

  Future<void> mergePeople(PersonCard source, PersonCard target) async {
    await database.queuePeople(
      PeopleCommand(
        id: _uuid.v4(),
        teamId: source.teamId,
        kind: 'merge_people',
        payload: {
          'id': source.id,
          'target_id': target.id,
          'target_version': target.version,
        },
        expectedVersion: source.version,
        dependencies: _peopleDependencies(persons: {source.id, target.id}),
      ),
    );
    await _refresh();
    _scheduleSync();
  }

  Future<void> discardPeopleChange(String id) async {
    await database.discardPeople(id);
    await _refresh();
  }

  Future<void> retryPeopleChange(PeopleCommand command) async {
    if (operationsKinds.contains(command.kind)) {
      await retryOperations(command);
      return;
    }
    var version = command.expectedVersion;
    final payload = {...command.payload};
    if (command.tripId == null) {
      version =
          (await database.serverPerson(payload['id'] as String))?['version']
              as int? ??
          0;
      if (command.kind == 'merge_people') {
        payload['target_version'] =
            (await database.serverPerson(
              payload['target_id'] as String,
            ))?['version'] ??
            0;
      }
    } else {
      final roster = await database.serverRoster(command.tripId!);
      if (command.kind == 'set_prices') {
        payload['lines'] = [
          for (final line in payload['lines'] as List)
            {
              ...Map<String, dynamic>.from(line as Map),
              'version':
                  (roster?['participations'] as List? ?? [])
                      .where((p) => p['id'] == line['id'])
                      .firstOrNull?['version'] ??
                  0,
            },
        ];
      } else if (command.kind == 'allocate_payment' ||
          command.kind == 'correct_payment') {
        version =
            (roster?['payments'] as List? ?? [])
                    .where((p) => p['id'] == payload['id'])
                    .firstOrNull?['version']
                as int? ??
            0;
      } else if (command.kind == 'set_status') {
        payload['versions'] = {
          for (final p in roster?['participations'] as List? ?? [])
            if ((payload['ids'] as List).contains(p['id']))
              p['id']: p['version'],
        };
      } else {
        final list =
            roster?[command.kind == 'save_booking'
                    ? 'bookings'
                    : 'participations']
                as List? ??
            [];
        version =
            list.where((p) => p['id'] == payload['id']).firstOrNull?['version']
                as int? ??
            0;
      }
    }
    await database.transaction(() async {
      await database.discardPeople(command.id);
      await database.queuePeople(
        PeopleCommand(
          id: _uuid.v4(),
          teamId: command.teamId,
          tripId: command.tripId,
          originTripId: command.originTripId,
          kind: command.kind,
          payload: payload,
          expectedVersion: version,
        ),
      );
    });
    await _refresh();
    _scheduleSync();
  }

  Future<void> clearAccountData() async {
    setOffline(true);
    await _syncFuture;
    await database.clearAccountData();
    await _refresh();
  }

  Future<void> queueFinance(
    String kind,
    JsonMap payload, {
    int expectedVersion = 0,
  }) async {
    final trip = selectedTrip;
    if (trip == null || !_finance.ready) {
      throw StateError('Сначала дождитесь загрузки платежей.');
    }
    if (!financeKinds.contains(kind)) {
      throw ArgumentError('Неизвестное действие.');
    }
    final booking = payload['booking_id'];
    final ids = kind == 'set_prices'
        ? (payload['lines'] as List).map((l) => l['id'] as String).toSet()
        : <String>{};
    final related = _people.commands
        .where(
          (c) =>
              c.tripId == trip.id &&
              ((financeKinds.contains(c.kind) &&
                      c.payload['booking_id'] == booking) ||
                  (c.kind == 'save_booking' && c.payload['id'] == booking) ||
                  c.participationIds.any(ids.contains)),
        )
        .toList();
    if (related.any((c) => c.error != null)) {
      throw StateError('Сначала разберите предыдущее изменение этой заявки.');
    }
    final body = {...payload};
    if (kind == 'add_payment') body['id'] ??= _uuid.v4();
    if (kind == 'correct_payment') {
      body['reversal_id'] = _uuid.v4();
      body['occurred_at'] = DateTime.now().toUtc().toIso8601String();
      if (body['replacement'] is Map) {
        body['replacement'] = {
          ...Map<String, dynamic>.from(body['replacement'] as Map),
          'id': _uuid.v4(),
        };
      }
    }
    await database.transaction(() async {
      await database.queuePeople(
        PeopleCommand(
          id: _uuid.v4(),
          teamId: trip.teamId,
          tripId: trip.id,
          kind: kind,
          payload: body,
          expectedVersion: expectedVersion,
          dependencies: related.map((c) => c.id).toList(),
        ),
      );
    });
    await _refresh();
    _scheduleSync();
  }

  Set<String> _operationKeys(String kind, JsonMap payload) => {
    for (final r in operationRows(payload['items'])) 'resource:${r['id']}',
    if (payload['resource_id'] != null) 'resource:${payload['resource_id']}',
    if (kind == 'ops_reservation') 'reservation:${payload['id']}',
    if (payload['reservation_id'] != null)
      'reservation:${payload['reservation_id']}',
    if (payload['subject_id'] != null)
      'subject:${payload['subject_kind'] ?? 'participant'}:${payload['subject_id']}',
    if (payload['swap_id'] != null) 'subject:participant:${payload['swap_id']}',
    if (kind == 'ops_settings') 'settings',
    if (kind == 'ops_cabins') 'cabins',
    if (kind == 'ops_move_escort')
      for (final id in (payload['versions'] as Map).keys) 'reservation:$id',
    if (kind == 'ops_resolve') 'fact:${payload['fact_id']}',
  };

  Future<void> queueOperations(
    String kind,
    JsonMap payload, {
    int expectedVersion = 0,
  }) => _queueOperations(selectedTrip, kind, payload, expectedVersion);

  Future<void> queueDuty(
    String tripId,
    JsonMap payload, {
    int expectedVersion = 0,
  }) {
    final trip = trips
        .where((t) => t.id == tripId && t.version > 0)
        .firstOrNull;
    if (trip == null || ['completed', 'cancelled'].contains(trip.status)) {
      throw StateError('Выезд недоступен для изменения графика.');
    }
    return _queueOperations(
      trip,
      'ops_reservation',
      {...payload, 'kind': 'duty'},
      expectedVersion,
      fromSchedule: true,
    );
  }

  Future<void> _queueOperations(
    Trip? trip,
    String kind,
    JsonMap payload,
    int expectedVersion, {
    bool fromSchedule = false,
  }) async {
    if (trip == null ||
        (!fromSchedule && !_operations.ready) ||
        !operationsKinds.contains(kind)) {
      throw StateError('Сначала дождитесь загрузки лодок и транспорта.');
    }
    final body = <String, dynamic>{...payload};
    if ([
      'ops_reservation',
      'ops_travel',
      'ops_presence',
      'ops_resolve',
    ].contains(kind)) {
      body['id'] ??= _uuid.v4();
    }
    if (kind == 'ops_presence') {
      body['previous_id'] ??= _operations.fact(
        body['reservation_id'] as String,
        body['subject_kind'] as String,
        body['subject_id'] as String,
      )?['id'];
      body['device_id'] = deviceId;
      body['occurred_at'] ??= DateTime.now().toUtc().toIso8601String();
    }
    if (kind == 'ops_resolve') {
      body['correction_id'] ??= _uuid.v4();
      body['device_id'] = deviceId;
    }
    final keys = _operationKeys(kind, body);
    final subject = body['subject_kind'] == 'employee'
        ? null
        : body['subject_id'];
    final related = _people.commands
        .where(
          (c) =>
              c.teamId == trip.teamId &&
              (c.kind != 'ops_cabins' || c.tripId == trip.id) &&
              ((operationsKinds.contains(c.kind) &&
                      (c.kind == 'ops_setup' ||
                          _operationKeys(
                            c.kind,
                            c.payload,
                          ).any(keys.contains))) ||
                  (c.tripId == trip.id &&
                      subject != null &&
                      c.participationIds.contains(subject)) ||
                  (c.kind == 'save_person' &&
                      operationRows(
                        body['items'],
                      ).any((r) => r['person_id'] == c.payload['id']))),
        )
        .toList();
    if (related.any((c) => c.error != null)) {
      throw StateError(
        'Сначала разберите предыдущее изменение этого места или ресурса.',
      );
    }
    // Projection and command are committed together: the projection is derived
    // only from persisted outbox rows, never an in-memory paid/assigned flag.
    await database.transaction(
      () => database.queuePeople(
        PeopleCommand(
          id: _uuid.v4(),
          teamId: trip.teamId,
          tripId: trip.id,
          kind: kind,
          payload: body,
          expectedVersion: expectedVersion,
          dependencies: related.map((c) => c.id).toList(),
        ),
      ),
    );
    await _refresh();
    _scheduleSync();
  }

  Future<void> initializeOperations() =>
      queueOperations('ops_setup', defaultOperationsSetup(_uuid.v4));

  Future<void> retryOperations(PeopleCommand command) async {
    final roster = await database.serverRoster(command.tripId!);
    final raw = Map<String, dynamic>.from(roster?['operations'] as Map? ?? {});
    final payload = <String, dynamic>{...command.payload};
    var version = 0;
    if (command.kind == 'ops_resources') {
      payload['items'] = [
        for (final item in operationRows(payload['items']))
          {
            ...item,
            'version':
                operationRows(
                  raw['resources'],
                ).where((r) => r['id'] == item['id']).firstOrNull?['version'] ??
                0,
          },
      ];
    } else if (command.kind == 'ops_reservation') {
      version =
          operationRows(
                raw['reservations'],
              ).where((r) => r['id'] == payload['id']).firstOrNull?['version']
              as int? ??
          0;
    } else if (command.kind == 'ops_crew') {
      version =
          operationRows(raw['crews'])
                  .where((r) => r['registration_id'] == payload['subject_id'])
                  .firstOrNull?['version']
              as int? ??
          0;
    } else if (command.kind == 'ops_travel') {
      final current = operationRows(raw['travel'])
          .where(
            (r) =>
                r['subject_kind'] == payload['subject_kind'] &&
                r['subject_id'] == payload['subject_id'] &&
                r['direction'] == payload['direction'],
          )
          .firstOrNull;
      version = current?['version'] as int? ?? 0;
      payload['id'] = current?['id'] ?? payload['id'];
    } else if (command.kind == 'ops_cabins') {
      // Keep the original version so a stale layout cannot replace another device's edits.
      version = command.expectedVersion;
    } else if (command.kind == 'ops_settings') {
      version = (raw['settings'] as Map?)?['version'] as int? ?? 0;
    } else if (command.kind == 'ops_presence') {
      final facts = operationRows(
        raw['presence'],
      ).where((r) => presenceKey(r) == presenceKey(payload));
      payload['previous_id'] = facts.lastOrNull?['id'];
    } else if (command.kind == 'ops_resolve') {
      throw StateError(
        'Откройте актуальное расхождение и укажите решение заново.',
      );
    }
    await database.transaction(() async {
      await database.discardPeople(command.id);
      await database.queuePeople(
        PeopleCommand(
          id: _uuid.v4(),
          teamId: command.teamId,
          tripId: command.tripId,
          kind: command.kind,
          payload: payload,
          expectedVersion: version,
        ),
      );
    });
    await _refresh();
    _scheduleSync();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> close() {
    dispose();
    return _closeFuture!;
  }

  Future<void> _closeDatabase() async {
    await _syncFuture;
    await database.close();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _pushTimer?.cancel();
    super.dispose();
    _closeFuture = _closeDatabase();
  }
}
