import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase/supabase.dart';
import 'package:uuid/uuid.dart';

import 'prototype_api.dart';
import 'prototype_database.dart';
import 'prototype_models.dart';

class PrototypeController extends ChangeNotifier {
  PrototypeController(
    this._database,
    this._api, {
    Duration? retryInterval = const Duration(seconds: 20),
  }) : _retryInterval = retryInterval;

  final PrototypeDatabase _database;
  final PrototypeApi _api;
  final Duration? _retryInterval;
  final _uuid = const Uuid();

  LocalGroupView _view = const LocalGroupView();
  Timer? _timer;
  Future<void>? _syncFuture;
  Future<void>? _closeFuture;
  bool _disposed = false;
  bool _isOffline = false;
  bool _isSyncing = false;
  String? _error;

  PrototypeGroup? get group => _view.group;
  List<PrototypeParticipant> get participants => _view.participants;
  DateTime? get lastSyncedAt => _view.lastSyncedAt;
  bool get isOffline => _isOffline;
  bool get isSyncing => _isSyncing;
  String? get error => _error;
  int get confirmedCount =>
      participants.where((p) => p.status == ParticipantStatus.confirmed).length;
  int get pendingCount =>
      participants.where((p) => p.status == ParticipantStatus.pending).length;

  Future<void> initialize({bool autoSync = true}) async {
    await _refresh();
    if (!autoSync || _disposed) return;
    final interval = _retryInterval;
    if (interval != null) {
      _timer = Timer.periodic(interval, (_) => unawaited(sync()));
    }
    unawaited(sync());
  }

  Future<void> addParticipant(String value) async {
    final name = value.trim();
    if (name.isEmpty || name.runes.length > 100) {
      throw ArgumentError('Введите имя длиной от 1 до 100 символов.');
    }
    if (group == null) throw StateError('Сначала загрузите группу.');
    await _database.enqueue(
      RegistrationCommand(
        operationId: _uuid.v4(),
        groupId: _api.groupId,
        personId: _uuid.v4(),
        registrationId: _uuid.v4(),
        name: name,
      ),
    );
    await _refresh();
    if (_syncFuture == null) {
      unawaited(sync());
    } else {
      // This command may have arrived after the running sync read its queue.
      unawaited(_syncFuture!.then((_) => sync()));
    }
  }

  void setOffline(bool value) {
    if (_disposed || _isOffline == value) return;
    _isOffline = value;
    _notify();
    if (!value) unawaited(sync());
  }

  Future<void> sync() {
    final current = _syncFuture;
    if (current != null) return current;
    if (_disposed || _isOffline) return Future.value();
    return _syncFuture = Future<void>.microtask(_runSync).whenComplete(() {
      _syncFuture = null;
    });
  }

  Future<void> _runSync() async {
    if (_disposed || _isOffline) return;
    _isSyncing = true;
    _error = null;
    _notify();
    try {
      await _api.prepare();
      final commands = await _database.pendingCommands(_api.groupId);
      for (final command in commands) {
        if (_disposed || _isOffline) return;
        final result = await _api.submit(command);
        final reason = result.reason;
        if (reason != null) await _database.reject(command, reason);
      }

      var cursor = _view.cursor;
      while (!_disposed && !_isOffline) {
        final page = await _api.pull(cursor);
        if (page.group.id != _api.groupId ||
            page.cursor < cursor ||
            (page.hasMore && page.cursor == cursor)) {
          throw const FormatException('Invalid group cursor');
        }
        await _database.applyPage(page);
        if (!page.hasMore) break;
        cursor = page.cursor;
      }
    } on GroupAccessDenied {
      await _database.forgetGroup(_api.groupId);
      _error = 'Доступ к группе отозван. Локальные данные группы удалены.';
    } on AuthException {
      _error = 'Не удалось войти. Проверьте учётные данные и подключение.';
    } on TimeoutException {
      _error =
          'Сервер не ответил. Сохранённые на устройстве изменения остаются в очереди.';
    } on SocketException {
      _error =
          'Нет связи с сервером. Сохранённые изменения остаются в очереди.';
    } catch (_) {
      _error =
          'Синхронизация прервалась. Повторите попытку после восстановления связи.';
    } finally {
      _isSyncing = false;
      try {
        await _refresh();
      } catch (_) {
        _error = 'Не удалось прочитать данные на устройстве.';
        _notify();
      }
    }
  }

  Future<void> _refresh() async {
    _view = await _database.readGroup(_api.groupId);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> close() {
    dispose();
    return _closeFuture!;
  }

  Future<void> _closeDatabase() async {
    try {
      await _syncFuture;
    } finally {
      await _database.close();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    super.dispose();
    _closeFuture = _closeDatabase();
  }
}
