import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

Future<QueryExecutor> openLocalStorage(String key) async {
  final directory = Directory(await _appDataDirectory());
  await directory.create(recursive: true);
  final file = File(p.join(directory.path, 'splav-$key.sqlite'));
  return NativeDatabase.createInBackground(file);
}

Future<String> _appDataDirectory() async {
  if (Platform.isAndroid) {
    const channel = MethodChannel('splav/storage');
    final path = await channel.invokeMethod<String>('getAppDataDirectory');
    if (path != null && path.isNotEmpty) return path;
  } else if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return p.join(localAppData, 'Splav');
    }
  }
  throw StateError('Не удалось определить папку данных приложения.');
}
