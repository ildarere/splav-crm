import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Stores an environment-specific session using the operating system's keys.
class SessionStore {
  SessionStore({required String scope})
    : _key = sha256.convert(utf8.encode(scope)).toString();

  static const _channel = MethodChannel('splav/session');
  final String _key;

  Future<String?> read() async {
    if (kIsWeb) return null;
    return _channel.invokeMethod<String>('read', {'key': _key});
  }

  Future<void> write(String value) async {
    // On the web, Supabase keeps the session in memory for the current page.
    if (kIsWeb) return;
    await _channel.invokeMethod<void>('write', {'key': _key, 'value': value});
  }

  Future<void> delete() async {
    if (kIsWeb) return;
    await _channel.invokeMethod<void>('delete', {'key': _key});
  }
}
